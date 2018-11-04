{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.LogRef
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
--
-- |
--
---------------------------------------------------------------------------------


module IDE.LogRef (
    nextError
,   previousError
,   nextBreakpoint
,   previousBreakpoint
,   markLogRefs
,   unmarkLogRefs
,   defaultLineLogger
,   defaultLineLogger'
,   foldOutputLines
,   logOutputLines
,   logOutputLines_
,   logOutputLinesDefault_
,   logOutput
,   logOutputDefault
,   logOutputPane
,   logIdleOutput
,   logOutputForBuild
,   logOutputForBreakpoints
,   logOutputForSetBreakpoint
,   logOutputForSetBreakpointDefault
,   logOutputForLiveContext
,   logOutputForLiveContextDefault
,   logOutputForHistoricContext
,   logOutputForHistoricContextDefault
,   selectRef
,   setBreakpointList
,   showSourceSpan
,   srcSpanParser
) where

import Prelude ()
import Prelude.Compat

import Control.Monad.Reader

import IDE.Core.State
import IDE.TextEditor
import IDE.Pane.SourceBuffer
import qualified IDE.Pane.Log as Log
import IDE.Utils.Tool
import System.FilePath (equalFilePath, makeRelative, isAbsolute, (</>))
import Data.List (partition, stripPrefix, elemIndex, isPrefixOf)
import Data.Maybe (fromMaybe, catMaybes, isJust)
import System.Exit (ExitCode(..))
import System.Log.Logger (debugM)
import IDE.Utils.FileUtils(myCanonicalizePath)
import IDE.Pane.Log (getDefaultLogLaunch, IDELog(..), getLog)
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Data.Conduit ((.|), ConduitT, (=$))
import IDE.Pane.WebKit.Output(setOutput)
import Data.IORef (atomicModifyIORef, IORef, readIORef)
import Data.Text (Text)
import Control.Applicative ((<$>), (<|>))
import qualified Data.Text as T
       (dropEnd, length, stripPrefix, isPrefixOf, unpack, unlines, pack,
        null)
import qualified Data.Set as S (notMember, member, insert, empty)
import Data.Set (Set)
import Data.Sequence (ViewR(..), Seq)
import qualified Data.Foldable as F (toList, forM_)
import qualified Data.Sequence as Seq
       (null, singleton, viewr, reverse, fromList)
import System.Directory (doesFileExist)
import Text.Read (readMaybe)
import IDE.Metainfo.WorkspaceCollector (srcSpanToLocation)
import Data.Attoparsec.Text
       (many', parseOnly, parse, endOfInput, option, anyChar, manyTill,
        takeText, (<?>), char, try, Parser)
import qualified Data.Attoparsec.Text as AP
       (takeWhile, decimal, string, skipSpace, takeWhile1)
import Data.Char (isDigit)
import Data.Attoparsec.Combinator (lookAhead)
import GHC.Stack (SrcLoc(..))
import Distribution.Text (simpleParse)
import Data.Void (Void)

showSourceSpan :: LogRef -> Text
showSourceSpan = T.pack . displaySrcSpan . logRefSrcSpan

selectRef :: Maybe LogRef -> IDEAction
selectRef (Just ref) = do
    mbBuf         <- selectSourceBuf (logRefFullFilePath ref)
    case mbBuf of
        Just buf  -> markRefInSourceBuf buf ref True
        Nothing   -> liftIO . void $ debugM "leksah" "no buf"
    log :: Log.IDELog <- Log.getLog
    maybe (return ()) (Log.markErrorInLog log) (logLines ref)
selectRef Nothing = return ()

forOpenLogRefs :: (LogRef -> IDEBuffer -> IDEAction) -> IDEAction
forOpenLogRefs f = do
    logRefs <- readIDE allLogRefs
    allBufs <- allBuffers
    F.forM_ logRefs $ \ref -> do
        let fp = logRefFullFilePath ref
        fpc <- liftIO $ myCanonicalizePath fp
        forM_ (filter (\buf -> case fileName buf of
                Just fn -> equalFilePath fpc fn
                Nothing -> False) allBufs) (f ref)

markLogRefs :: IDEAction
markLogRefs =
    forOpenLogRefs $ \logRef buf -> markRefInSourceBuf buf logRef False

unmarkLogRefs :: IDEAction
unmarkLogRefs =
    forOpenLogRefs $ \logRef IDEBuffer {sourceView = sv} -> do
            buf     <-  getBuffer sv
            removeTagByName buf (T.pack $ show (logRefType logRef))

setBreakpointList :: Seq LogRef -> IDEAction
setBreakpointList breaks = do
    ideR <- ask
    unmarkLogRefs
    errs <- readIDE errorRefs
    contexts <- readIDE contextRefs
    modifyIDE_ (\ide -> ide{allLogRefs = errs <> breaks <> contexts})
    setCurrentBreak Nothing
    markLogRefs
    triggerEventIDE BreakpointChanged
    return ()

addLogRefs :: Seq LogRef -> IDEAction
addLogRefs refs = do
    ideR <- ask
    unmarkLogRefs
    modifyIDE_ (\ide -> ide{allLogRefs = allLogRefs ide <> refs})
    setCurrentError Nothing
    markLogRefs
    triggerEventIDE (ErrorChanged False)
    triggerEventIDE BreakpointChanged
    triggerEventIDE TraceChanged
    return ()

next :: (IDE -> Seq LogRef)
     -> (IDE -> Maybe LogRef)
     -> (Maybe LogRef -> IDEAction)
     -> IDEAction
next all current set = do
    all <- F.toList <$> readIDE all
    current <- readIDE current
    let isCurrent = (== current) . Just
    case dropWhile isCurrent (dropWhile (not . isCurrent) all) <> all of
        (n:_) -> do
            set (Just n)
            selectRef (Just n)
        _ -> return ()

nextError :: IDEAction
nextError = next errorRefs currentError setCurrentError

previousError :: IDEAction
previousError = next (Seq.reverse . errorRefs) currentError setCurrentError

nextBreakpoint :: IDEAction
nextBreakpoint = next breakpointRefs currentBreak setCurrentBreak

previousBreakpoint :: IDEAction
previousBreakpoint = next (Seq.reverse . breakpointRefs) currentBreak setCurrentBreak

nextContext :: IDEAction
nextContext = next contextRefs currentContext setCurrentContext

previousContext :: IDEAction
previousContext = next (Seq.reverse . contextRefs) currentContext setCurrentContext

lastContext :: IDEAction
lastContext = do
    contexts <- readIDE contextRefs
    currentContext <- readIDE currentContext
    case contexts of
        (Seq.viewr -> _ :> l) -> do
            setCurrentContext $ Just l
            selectRef $ Just l
        _ -> return ()

fixColumn c = max 0 (c - 1)

srcPathParser :: Parser FilePath
srcPathParser = T.unpack <$> (try (do
        symbol "dist/build/tmp-" -- Support for cabal haddock
        AP.takeWhile1 isDigit
        char '/'
        AP.takeWhile (/=':'))
    <|> AP.takeWhile (/=':'))

srcSpanParser :: Parser SrcSpan
srcSpanParser = try (do
        filePath <- srcPathParser
        char ':'
        char '('
        beginLine <- int
        char ','
        beginCol <- int
        char ')'
        char '-'
        char '('
        endLine <- int
        char ','
        endCol <- int
        char ')'
        return $ SrcSpan filePath beginLine (fixColumn beginCol) endLine (fixColumn endCol))
    <|> try (do
        filePath <- srcPathParser
        char ':'
        line <- int
        char ':'
        beginCol <- int
        char '-'
        endCol <- int
        return $ SrcSpan filePath line (fixColumn beginCol) line (fixColumn endCol))
    <|> try (do
        filePath <- srcPathParser
        char ':'
        line <- int
        char ':'
        col <- int
        return $ SrcSpan filePath line (fixColumn col) line (fixColumn col))
    <|> try (do
        filePath <- srcPathParser
        char ':'
        line <- int
        return $ SrcSpan filePath line 0 line 0)
    <?> "srcSpanParser"

data BuildOutput = BuildProgress Int Int FilePath
                 | DocTestFailure SrcSpan Text

buildOutputParser :: Parser BuildOutput
buildOutputParser = try (do
        char '['
        whiteSpace
        n <- int
        whiteSpace
        symbol "of"
        whiteSpace
        total <- int
        char ']'
        whiteSpace
        symbol "Compiling"
        AP.takeWhile (/= '(')
        char '('
        whiteSpace
        file <- AP.takeWhile (/= ',')
        char ','
        text <- takeText
        return $ BuildProgress n total (T.unpack file))
    <|> try (do
        symbol "###"
        whiteSpace
        symbol "Failure"
        whiteSpace
        symbol "in"
        whiteSpace
        file <- AP.takeWhile (/= ':')
        char ':'
        line <- int
        char ':'
        whiteSpace
        text <- takeText
        let colGuess = T.length $ case T.unpack text of
                        ('\\':_) -> "-- prop> "
                        _        -> "-- >>> "
        return $ DocTestFailure (SrcSpan (T.unpack file) line colGuess line (T.length text - colGuess)) $ "Failure in " <> text)
    <?> "buildOutputParser"

data BuildError =   BuildLine
                |   EmptyLine
                |   ErrorLine SrcSpan LogRefType Text
                |   WarningLine Text
                |   OtherLine Text
                |   ElmFile FilePath Text
                |   ElmLine Int
                |   ElmPointLine Int
                |   ElmColumn Int Int

buildErrorParser :: Parser BuildError
buildErrorParser = try (do
        char '['
        whiteSpace
        int
        whiteSpace
        symbol "of"
        whiteSpace
        int
        whiteSpace
        char ']'
        takeText
        return BuildLine)
    <|> try (do
        -- Nix format
        symbol "error: "
        text <- T.pack <$> manyTill anyChar (symbol ", at ")
        span <- srcSpanParser
        return (ErrorLine span ErrorRef text))
    <|> try (do
        whiteSpace
        span <- srcSpanParser
        char ':'
        whiteSpace
        refType <- try (do
                symbol "Warning:" <|> symbol "warning:"
                return WarningRef)
            <|> (do
                symbol "Error:" <|> symbol "error:"
                return ErrorRef)
            <|> (do
                symbol "failure"
                return TestFailureRef)
            <|> return ErrorRef
        text <- takeText
        return (ErrorLine span refType text))
    <|> try (do
        char '-'
        char '-'
        char ' '
        whiteSpace
        text <- T.dropEnd 1 <$> AP.takeWhile (/= '-')
        char '-'
        char '-'
        AP.takeWhile (== '-')
        whiteSpace
        option () (char '.' >> char '/' >> pure ())
        file <- takeText
        return (ElmFile (T.unpack file) text))
    <|> try (do
        line <- int
        char '|'
        pointer <- char '>' <|> char ' '
        text <- takeText
        return $ (case pointer of
                    '>' -> ElmPointLine
                    _   -> ElmLine) line)
    <|> try (do
        col1 <- T.length <$> AP.takeWhile (== ' ')
        char '^'
        col2 <- T.length <$> AP.takeWhile (== '^')
        endOfInput
        return (ElmColumn col1 (col1 + col2)))
    <|> try (do
        whiteSpace
        endOfInput
        return EmptyLine)
    <|> try (do
        whiteSpace
        warning <- symbol "Warning:" <|> symbol "warning:"
        text <- takeText
        return (WarningLine (warning <> text)))
    <|> try (do
        text <- takeText
        endOfInput
        return (OtherLine text))
    <?> "buildLineParser"

data BreakpointDescription = BreakpointDescription Int SrcSpan

breaksLineParser :: Parser BreakpointDescription
breaksLineParser = try (do
        char '['
        n <- int
        char ']'
        whiteSpace
        AP.takeWhile (/=' ')
        whiteSpace
        span <- srcSpanParser
        return (BreakpointDescription n span))
    <?> "breaksLineParser"

setBreakpointLineParser :: Parser BreakpointDescription
setBreakpointLineParser = try (do
        symbol "Breakpoint"
        whiteSpace
        n <- int
        whiteSpace
        symbol "activated"
        whiteSpace
        symbol "at"
        whiteSpace
        span <- srcSpanParser
        return (BreakpointDescription n span))
    <?> "setBreakpointLineParser"

whiteSpace = AP.skipSpace
symbol = AP.string
int = AP.decimal

defaultLineLogger :: IDELog -> LogLaunch -> ToolOutput -> IDEM Int
defaultLineLogger log logLaunch out = liftIO $ defaultLineLogger' log logLaunch out

defaultLineLogger' :: IDELog -> LogLaunch -> ToolOutput -> IO Int
defaultLineLogger' log logLaunch out =
    case out of
        ToolInput  line            -> appendLog' (line <> "\n") InputTag
        ToolOutput line            -> appendLog' (line <> "\n") LogTag
        ToolError  line            -> appendLog' (line <> "\n") ErrorTag
        ToolPrompt line            -> do
            unless (T.null line) $ void (appendLog' (line <> "\n") LogTag)
            appendLog' (T.pack (concat (replicate 20 "- ")) <> "-\n") FrameTag
        ToolExit   ExitSuccess     -> appendLog' (T.pack (replicate 41 '-') <> "\n") FrameTag
        ToolExit   (ExitFailure 1) -> appendLog' (T.pack (replicate 41 '=') <> "\n") FrameTag
        ToolExit   (ExitFailure n) -> appendLog' (T.pack (take 41 ("========== " ++ show n <> " " ++ repeat '=')) <> "\n") FrameTag
    where
        appendLog' = Log.appendLog log logLaunch

paneLineLogger :: IDELog -> LogLaunch -> ToolOutput -> IDEM (Maybe Text)
paneLineLogger log logLaunch out = liftIO $ paneLineLogger' log logLaunch out

paneLineLogger' :: IDELog -> LogLaunch -> ToolOutput -> IO (Maybe Text)
paneLineLogger' log logLaunch out =
    case out of
        ToolInput  line            -> appendLog' (line <> "\n") InputTag >> return Nothing
        ToolOutput line            -> appendLog' (line <> "\n") LogTag >> return (Just line)
        ToolError  line            -> appendLog' (line <> "\n") ErrorTag >> return Nothing
        ToolPrompt line            -> do
            unless (T.null line) $ void (appendLog' (line <> "\n") LogTag)
            appendLog' (T.pack (concat (replicate 20 "- ")) <> "-\n") FrameTag
            return Nothing
        ToolExit   ExitSuccess     -> appendLog' (T.pack (replicate 41 '-') <> "\n") FrameTag >> return Nothing
        ToolExit   (ExitFailure 1) -> appendLog' (T.pack (replicate 41 '=') <> "\n") FrameTag >> return Nothing
        ToolExit   (ExitFailure n) -> appendLog' (T.pack (take 41 ("========== " ++ show n ++ " " ++ repeat '=')) <> "\n") FrameTag >> return Nothing
    where
        appendLog' = Log.appendLog log logLaunch

foldOutputLines :: LogLaunch -- ^ logLaunch
               -> (IDELog -> LogLaunch -> a -> ToolOutput -> IDEM a)
               -> a
               -> ConduitT ToolOutput Void IDEM a
foldOutputLines logLaunch lineLogger a = do
    log :: Log.IDELog <- lift $ postSyncIDE Log.getLog
    results <- CL.foldM (\a b -> postSyncIDE $ lineLogger log logLaunch a b) a
    lift . postSyncIDE $ triggerEventIDE (StatusbarChanged [CompartmentState "", CompartmentBuild False])
    return results

logOutputLines :: LogLaunch -- ^ logLaunch
               -> (IDELog -> LogLaunch -> ToolOutput -> IDEM a)
               -> ConduitT ToolOutput Void IDEM [a]
logOutputLines logLaunch lineLogger = do
    log :: Log.IDELog <- lift $ postSyncIDE Log.getLog
    results <- CL.mapM (postSyncIDE . lineLogger log logLaunch) .| CL.consume
    lift . postSyncIDE $ triggerEventIDE (StatusbarChanged [CompartmentState "", CompartmentBuild False])
    return results

logOutputLines_ :: LogLaunch
                -> (IDELog -> LogLaunch -> ToolOutput -> IDEM a)
                -> ConduitT ToolOutput Void IDEM ()
logOutputLines_ logLaunch lineLogger = do
    logOutputLines logLaunch lineLogger
    return ()

logOutputLinesDefault_ :: (IDELog -> LogLaunch -> ToolOutput -> IDEM a)
                       -> ConduitT ToolOutput Void IDEM ()
logOutputLinesDefault_ lineLogger = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    logOutputLines_  defaultLogLaunch lineLogger

logOutput :: LogLaunch
          -> ConduitT ToolOutput Void IDEM ()
logOutput logLaunch = do
    logOutputLines logLaunch defaultLineLogger
    return ()

logOutputDefault :: ConduitT ToolOutput Void IDEM ()
logOutputDefault = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    logOutput defaultLogLaunch

logOutputPane :: Text -> IORef [Text] -> ConduitT ToolOutput Void IDEM ()
logOutputPane command buffer = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    result <- catMaybes <$> logOutputLines defaultLogLaunch paneLineLogger
    unless (null result) $ do
        liftIO $ debugM "leskah" "logOutputPane has result"
        new <- liftIO . atomicModifyIORef buffer $ \x -> let new = x ++ result in (new, new)
        mbURI <- lift $ readIDE autoURI
        unless (isJust mbURI) . lift . postSyncIDE . setOutput command $ T.unlines new

idleOutputParser :: Parser SrcLoc
idleOutputParser = try (do
        symbol "OPEN"
        whiteSpace
        span <- srcSpanParser
        whiteSpace
        symbol "in"
        whiteSpace
        package <- AP.takeWhile (/=':')
        char ':'
        mod <- takeText
        return $ SrcLoc (T.unpack package) (T.unpack mod) (srcSpanFilename span)
            (srcSpanStartLine span) (srcSpanStartColumn span)
            (srcSpanEndLine span) (srcSpanEndColumn span))
    <?> "idleOutputParser"

logIdleOutput
    :: Project
    -> IDEPackage
    -> ConduitT ToolOutput Void IDEM ()
logIdleOutput project package = loop
  where
    loop = C.await >>= maybe (return ()) (\output -> do
        case output of
            ToolError s ->
                case parseOnly idleOutputParser s of
                    Left _ -> return ()
                    Right srcLoc ->
                        lift . liftIDE . postSyncIDE $ do
--                            descrs <- getSymbols symbol
--                            case (simpleParse $ srcLocPackage loc, simpleParse $ srcSpan) of
--                                (Just pid, Just mName) -> do
--                                    descrs <- getSymbols symbol
--                                    case filter (\case
--                                            Real rd -> dscMbModu' rd == Just (PM pid mName)
--                                            _ -> False) descrs of
--                                        [a] -> do
--                                            liftIO . tryPutMVar lookup . Just . postAsyncIDE $ selectIdentifier a activatePanes openDefinition
--                                            return True
--                                        _   -> return worked
--                                _ -> return worked

                            log <- liftIO $ findLog project (LogCabal $ ipdCabalFile package) (srcLocFile srcLoc)
                            let loc = Location (srcLocFile srcLoc) (srcLocStartLine srcLoc) (srcLocStartCol srcLoc + 1) (srcLocEndLine srcLoc) (srcLocEndCol srcLoc)
                            goToSourceDefinition (logRootPath log) loc >>= \case
                                Just pane -> bringPaneToFront pane
                                Nothing -> goToLocation (PM
                                                <$> packageIdentifierFromString (T.pack $ srcLocPackage srcLoc)
                                                <*> simpleParse (srcLocModule srcLoc)) $ Just loc
            _ -> return ()
        loop)

data BuildOutputState = BuildOutputState { log           :: IDELog
                                         , inError       :: Bool
                                         , inDocTest     :: Bool
                                         , errs          :: [LogRef]
                                         , elmLine       :: Int
                                         , testFails     :: [LogRef]
                                         , filesCompiled :: Set FilePath
                                         }

-- Not quite a Monoid
initialState :: IDELog -> BuildOutputState
initialState log = BuildOutputState log False False [] 1 [] S.empty

-- Sometimes we get error spans relative to a build dependency
findLog :: Project -> Log -> FilePath -> IO Log
findLog project log file =
    doesFileExist (logRootPath log </> file) >>= \case
        True -> return log
        False ->
            -- If the file only exists in one package in the project it is probably the right one
            filterM (\p -> doesFileExist $ ipdPackageDir p </> file) (pjPackages project) >>= \case
                [p] -> return . LogCabal $ ipdCabalFile p
                _   -> return log -- Not really sure where this file is

logOutputForBuild :: Project
                  -> Log
                  -> Bool
                  -> Bool
                  -> ConduitT ToolOutput Void IDEM [LogRef]
logOutputForBuild project logSource backgroundBuild jumpToWarnings = do
    liftIO $ debugM "leksah" "logOutputForBuild"
    log    <- lift getLog
    logLaunch <- lift Log.getDefaultLogLaunch
    -- Elm does not log files compiled so just clear all the log refs for elm files
    lift $ postSyncIDE $ removeFileExtLogRefs logSource ".elm" [ErrorRef, WarningRef]
    lift $ postSyncIDE $ removeFileExtLogRefs logSource ".nix" [ErrorRef, WarningRef]
    BuildOutputState {..} <- CL.foldM (readAndShow logLaunch) $ initialState log
    lift $ postSyncIDE $ do
        allErrorLikeRefs <- readIDE errorRefs
        triggerEventIDE (Sensitivity [(SensitivityError,not (Seq.null allErrorLikeRefs))])
        let errorNum    =   length (filter isError errs)
        let warnNum     =   length errs - errorNum
        triggerEventIDE (StatusbarChanged [CompartmentState
            (T.pack $ show errorNum ++ " Errors, " ++ show warnNum ++ " Warnings"), CompartmentBuild False])
        return errs
  where
    readAndShow :: LogLaunch -> BuildOutputState -> ToolOutput -> IDEM BuildOutputState
    readAndShow logLaunch state@BuildOutputState {..} output = do
        ideR <- ask
        let logPrevious (previous:_) = reflectIDE (addLogRef False backgroundBuild previous) ideR
            logPrevious _ = return ()
        liftIDE $ postSyncIDE $ liftIO $ do
          debugM "leksah" $ "readAndShow " ++ show output
          case output of
            -- stack prints everything to stderr, so let's process errors as normal output first
            ToolError line -> processNormalOutput ideR logLaunch state logPrevious line $ do
                let parsed  =  parseOnly buildErrorParser line
                let nonErrorPrefixes = ["Linking ", "ar:", "ld:", "ld warning:"]
                tag <- case parsed of
                    Right BuildLine -> return InfoTag
                    Right (OtherLine text) | "Linking " `T.isPrefixOf` text ->
                        -- when backgroundBuild $ lift interruptProcess
                        return InfoTag
                    Right (OtherLine text) | any (`T.isPrefixOf` text) nonErrorPrefixes ->
                        return InfoTag
                    _ -> return ErrorTag
                lineNr <- Log.appendLog log logLaunch (line <> "\n") tag
                case (parsed, errs, testFails) of
                    (Left e, _, _) -> do
                        sysMessage Normal . T.pack $ show e
                        return state { inError = False }
                    (Right ne@(ErrorLine span refType str), _, _) -> do
                        foundLog <- findLog project logSource (srcSpanFilename span)
                        let ref  = LogRef span foundLog str Nothing (Just (lineNr,lineNr)) refType
                            root = logRefRootPath ref
                            file = logRefFilePath ref
                            fullFilePath = logRefFullFilePath ref
                        unless (fullFilePath `S.member` filesCompiled) $
                            reflectIDE (removeBuildLogRefs (root </> file)) ideR
                        when inError $ logPrevious errs
                        return state { inError = True
                                     , errs = ref:errs
                                     , elmLine = 1
                                     , filesCompiled = S.insert fullFilePath filesCompiled
                                     }
                    (Right (ElmFile efile str), _, _) -> do
                        let ref  = LogRef (SrcSpan efile 1 0 1 0) logSource str Nothing (Just (lineNr,lineNr)) ErrorRef
                            root = logRefRootPath ref
                            file = logRefFilePath ref
                            fullFilePath = logRefFullFilePath ref
                        when inError $ logPrevious errs
                        return state { inError = True
                                     , errs = ref:errs
                                     , elmLine = 1
                                     , filesCompiled = S.insert fullFilePath filesCompiled
                                     }
                    (Right (ElmLine eline), _, _) ->
                        if inError
                            then return state
                                { elmLine = eline
                                }
                            else return state
                    (Right (ElmPointLine eline), ref:tl, _) ->
                        if inError
                            then return state
                                { errs = ref
                                    { logRefSrcSpan =
                                        case logRefSrcSpan ref of
                                             SrcSpan f 1 0 1 0 -> SrcSpan f eline 0 (eline + 1) 0
                                             SrcSpan f l _ _ _ -> SrcSpan f l     0 (eline + 1) 0
                                    } : tl
                                }
                            else return state
                    (Right (ElmColumn c1 c2), ref@LogRef{logRefSrcSpan = span}:tl, _) ->
                        if inError
                            then do
                                let line = max 1 elmLine
                                    leftMargin = 2 + length (show line)
                                return state
                                    { errs = ref
                                        { logRefSrcSpan = (logRefSrcSpan ref)
                                            { srcSpanStartColumn = max 0 (c1 - leftMargin)
                                            , srcSpanEndColumn = max 0 (c2 - leftMargin)
                                            , srcSpanStartLine = line
                                            , srcSpanEndLine = line
                                            }
                                        } : tl
                                    }
                            else return state
                    (Right (OtherLine str1), LogRef span rootPath str Nothing (Just (l1,l2)) refType:tl, _)
                        | inError -> return state
                                { errs = LogRef span rootPath
                                            (if T.null str then line else str <> "\n" <> line)
                                            Nothing
                                            (Just (l1, lineNr))
                                            refType
                                            : tl
                                }
                    (Right (OtherLine str1), _, LogRef span rootPath str Nothing (Just (l1,l2)) refType:tl)
                        | inDocTest -> return state
                                { testFails = LogRef span rootPath
                                            (if T.null str then line else str <> "\n" <> line)
                                            Nothing
                                            (Just (l1,lineNr))
                                            refType
                                            : tl
                                }
                    (Right (OtherLine str1), _, _) -> return state
                    (Right (WarningLine str1), LogRef span rootPath str Nothing (Just (l1, l2)) isError : tl, _) ->
                        if inError
                            then return state { errs = LogRef span rootPath
                                                         (if T.null str then line else str <> "\n" <> line)
                                                         Nothing
                                                         (Just (l1, lineNr))
                                                         WarningRef
                                                         : tl
                                              }
                            else return state
                    (Right EmptyLine, _, _) -> return state -- Elm errors can contain empty lines
                    _ -> do
                        when inError $ logPrevious errs
                        when inDocTest $ logPrevious testFails
                        return state { inError = False, inDocTest = False }
            ToolOutput line ->
                processNormalOutput ideR logLaunch state logPrevious line $
                  case (inDocTest, testFails) of
                    (True, LogRef span rootPath str Nothing (Just (l1, l2)) refType : tl) -> do
                        logLn <- Log.appendLog log logLaunch (line <> "\n") ErrorTag
                        return state { testFails = LogRef span
                                            rootPath
                                            (str <> "\n" <> line)
                                            Nothing (Just (l1,logLn)) TestFailureRef : tl
                                     }
                    _ -> do
                        Log.appendLog log logLaunch (line <> "\n") LogTag
                        when inDocTest $ logPrevious testFails
                        return state { inDocTest = False }
            ToolInput line -> do
                Log.appendLog log logLaunch (line <> "\n") InputTag
                return state
            ToolPrompt line -> do
                unless (T.null line) . void $ Log.appendLog log logLaunch (line <> "\n") LogTag
                when inError $ logPrevious errs
                when inDocTest $ logPrevious testFails
                let errorNum    =   length (filter isError errs)
                let warnNum     =   length errs - errorNum
                case errs of
                    [] -> defaultLineLogger' log logLaunch output
                    _ -> Log.appendLog log logLaunch (T.pack $ "- - - " ++ show errorNum ++ " errors - "
                                            ++ show warnNum ++ " warnings - - -\n") FrameTag
                return state { inError = False, inDocTest = False }
            ToolExit _ -> do
                let errorNum    =   length (filter isError errs)
                    warnNum     =   length errs - errorNum
                when inError $ logPrevious errs
                when inDocTest $ logPrevious testFails
                case (errs, testFails) of
                    ([], []) -> defaultLineLogger' log logLaunch output
                    _ -> Log.appendLog log logLaunch (T.pack $ "----- " ++ show errorNum ++ " errors -- "
                                            ++ show warnNum ++ " warnings -- "
                                            ++ show (length testFails) ++ " doctest failures -----\n") FrameTag
                return state { inError = False, inDocTest = False }
    -- process output line as normal, otherwise calls given alternative
    processNormalOutput :: IDERef -> LogLaunch -> BuildOutputState -> ([LogRef]->IO()) -> Text -> IO BuildOutputState -> IO BuildOutputState
    processNormalOutput ideR logLaunch state@BuildOutputState {..} logPrevious line altFunction =
      case parseOnly buildOutputParser line of
        (Right (BuildProgress n total file)) -> do
            logLn <- Log.appendLog log logLaunch (line <> "\n") LogTag
            reflectIDE (triggerEventIDE (StatusbarChanged [CompartmentState
                (T.pack $ "Compiling " ++ show n ++ " of " ++ show total), CompartmentBuild False])) ideR
            f <- if isAbsolute file
                    then return file
                    else (</> file) . logRootPath <$> findLog project logSource file
            reflectIDE (removeBuildLogRefs f) ideR
            when inDocTest $ logPrevious testFails
            return state { inDocTest = False }
        (Right (DocTestFailure span exp)) -> do
            logLn <- Log.appendLog log logLaunch (line <> "\n") ErrorTag
            when inError $ logPrevious errs
            when inDocTest $ logPrevious testFails
            return state { inDocTest = True
                         , inError = False
                         , testFails = LogRef span
                                logSource
                                exp
                                Nothing (Just (logLn,logLn)) TestFailureRef : testFails
                         }
        _ -> altFunction

--logOutputLines :: Text -- ^ logLaunch
--               -> (LogLaunch -> ToolOutput -> IDEM a)
--               -> [ToolOutput]
--               -> IDEM [a]

logOutputForBreakpoints :: IDEPackage
                        -> LogLaunch           -- ^ loglaunch
                        -> ConduitT ToolOutput Void IDEM ()
logOutputForBreakpoints package logLaunch = do
    breaks <- logOutputLines logLaunch (\log logLaunch out -> postSyncIDE $
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ Log.appendLog log logLaunch (line <> "\n") LogTag
                case parseOnly breaksLineParser line of
                    Right (BreakpointDescription n span) ->
                        return $ Just $ LogRef span (LogCabal $ ipdCabalFile package) line Nothing (Just (logLineNumber, logLineNumber)) BreakpointRef
                    _ -> return Nothing
            _ -> do
                defaultLineLogger log logLaunch out
                return Nothing)
    lift . setBreakpointList . Seq.fromList $ catMaybes breaks

logOutputForSetBreakpoint :: FilePath
                        -> LogLaunch           -- ^ loglaunch
                        -> ConduitT ToolOutput Void IDEM ()
logOutputForSetBreakpoint basePath logLaunch = do
    breaks <- logOutputLines logLaunch (\log logLaunch out ->
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ Log.appendLog log logLaunch (line <> "\n") LogTag
                case parseOnly setBreakpointLineParser line of
                    Right (BreakpointDescription n span) ->
                        return $ Just $ LogRef span (LogProject basePath) line Nothing (Just (logLineNumber, logLineNumber)) BreakpointRef
                    _ -> return Nothing
            _ -> do
                defaultLineLogger log logLaunch out
                return Nothing)
    lift . postSyncIDE . addLogRefs . Seq.fromList $ catMaybes breaks

logOutputForSetBreakpointDefault :: FilePath
                                 -> ConduitT ToolOutput Void IDEM ()
logOutputForSetBreakpointDefault basePath = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    logOutputForSetBreakpoint basePath defaultLogLaunch

logOutputForContext :: FilePath
                    -> LogLaunch                   -- ^ loglaunch
                    -> (Text -> [SrcSpan])
                    -> ConduitT ToolOutput Void IDEM ()
logOutputForContext basePath loglaunch getContexts = do
    refs <- catMaybes <$> logOutputLines loglaunch (\log logLaunch out ->
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ Log.appendLog log logLaunch (line <> "\n") LogTag
                let contexts = getContexts line
                if null contexts
                    then return Nothing
                    else return $ Just $ LogRef (last contexts) (LogProject basePath) line Nothing (Just (logLineNumber, logLineNumber)) ContextRef
            _ -> do
                defaultLineLogger log logLaunch out
                return Nothing)
    lift . unless (null refs) . postSyncIDE $ do
        addLogRefs . Seq.singleton $ last refs
        lastContext

contextParser :: Parser SrcSpan
contextParser = try (do
        whiteSpace
        symbol "Logged breakpoint at" <|> symbol "Stopped at"
        whiteSpace
        srcSpanParser)
    <?> "contextParser"

contextsParser :: Parser [SrcSpan]
contextsParser = try (
        catMaybes <$> many' (
              (Just <$> contextParser)
          <|> (anyChar >> pure Nothing)))
    <?> "contextsParser"

logOutputForLiveContext :: FilePath
                        -> LogLaunch           -- ^ loglaunch
                        -> ConduitT ToolOutput Void IDEM ()
logOutputForLiveContext basePath logLaunch = logOutputForContext basePath logLaunch getContexts
    where
        getContexts line = either (const []) id $ parseOnly contextsParser line

logOutputForLiveContextDefault :: FilePath
                               -> ConduitT ToolOutput Void IDEM ()
logOutputForLiveContextDefault basePath = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    logOutputForLiveContext basePath defaultLogLaunch


logOutputForHistoricContext :: FilePath
                            -> LogLaunch           -- ^ loglaunch
                            -> ConduitT ToolOutput Void IDEM ()
logOutputForHistoricContext basePath logLaunch = logOutputForContext basePath logLaunch getContexts
    where
        getContexts line = case parseOnly contextParser line of
                                Right desc -> [desc]
                                _          -> []

logOutputForHistoricContextDefault :: FilePath
                                   -> ConduitT ToolOutput Void IDEM ()
logOutputForHistoricContextDefault basePath = do
    defaultLogLaunch <- lift getDefaultLogLaunch
    logOutputForHistoricContext basePath defaultLogLaunch
