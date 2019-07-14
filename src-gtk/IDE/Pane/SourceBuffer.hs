{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.SourceBuffer
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- | The source editor part of Leksah
--
-----------------------------------------------------------------------------------

module IDE.Pane.SourceBuffer (
    IDEBuffer(..)
,   BufferState(..)

,   allBuffers
,   maybeActiveBuf
,   selectSourceBuf
,   goToSourceDefinition
,   goToSourceDefinition'
,   goToDefinition
,   goToLocation
,   insertInBuffer

,   fileNew
,   fileOpenThis
,   filePrint
,   fileRevert
,   fileClose
,   fileCloseAll
,   fileCloseAllButPackage
,   fileCloseAllButWorkspace
,   fileSave
,   fileSaveAll
,   fileSaveBuffer
,   fileCheckAll
,   editUndo
,   editRedo
,   editCut
,   editCopy
,   editPaste
,   editDelete
,   editSelectAll

,   editReformat
,   editComment
,   editUncomment
,   editShiftRight
,   editShiftLeft

,   editToCandy
,   editFromCandy
,   editKeystrokeCandy
,   switchBuffersCandy

,   updateStyle
,   updateStyle'
,   addLogRef
,   removeLogRefs
,   removeBuildLogRefs
,   removeFileExtLogRefs
,   removeTestLogRefs
,   removeLintLogRefs
,   markRefInSourceBuf
,   unmarkRefInSourceBuf
,   inBufContext
,   inActiveBufContext

,   align
,   startComplete

,   selectedText
,   selectedTextOrCurrentLine
,   selectedTextOrCurrentIdentifier
,   insertTextAfterSelection
,   selectedModuleName
,   selectedLocation
,   recentSourceBuffers
,   newTextBuffer
,   belongsToPackages
,   belongsToPackages'
,   belongsToPackage
,   belongsToWorkspace
,   belongsToWorkspace'
,   getIdentifierUnderCursorFromIter
,   useCandyFor
,   setModifiedOnDisk

) where

import Prelude ()
import Prelude.Compat hiding(getChar, getLine)

import Control.Applicative ((<|>))
import Control.Concurrent (modifyMVar_, putMVar, takeMVar, newMVar, tryPutMVar)
import Control.Event (triggerEvent)
import Control.Exception as E (catch, SomeException)
import Control.Lens ((.~), (%~), (^.), to)
import Control.Monad (filterM, void, unless, when, forM_)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Reader (ask)

import Data.Char (isSymbol, isSpace, isAlphaNum)
import qualified Data.Foldable as F (Foldable(..), forM_)
import Data.IORef (writeIORef,readIORef,newIORef)
import Data.List (isPrefixOf)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
       (mapMaybe, fromJust, isNothing, isJust, fromMaybe)
import Data.Sequence (ViewR(..))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
       (singleton, isInfixOf, breakOn, length, replicate,
        lines, dropWhileEnd, unlines, strip, null, pack, unpack)
import qualified Data.Text.IO as T (writeFile, readFile)
import Data.Time (UTCTime(..))
import Data.Time.Clock (addUTCTime, diffUTCTime)
-- import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Traversable (forM)
import Data.Typeable (cast)

import System.Directory
       (getHomeDirectory, getModificationTime, doesFileExist)
import System.FilePath
       (splitDirectories, (</>), dropFileName,
        equalFilePath, takeFileName)
import System.Log.Logger (errorM, warningM, debugM)

import Data.GI.Base (new')
import Data.GI.Base.ManagedPtr (unsafeCastTo)
import GI.Gdk (windowGetOrigin)
import GI.Gdk.Enums (EventType(..))
import GI.Gdk.Functions (keyvalName)
import GI.Gdk.Flags (ModifierType(..))
import GI.Gdk.Structs.Atom (atomIntern)
import GI.Gdk.Structs.EventButton (getEventButtonType)
import GI.Gdk.Structs.EventKey
       (getEventKeyState, getEventKeyKeyval)
import GI.Gtk
       (bindingsActivateEvent, onDialogResponse, widgetShowAll,
        boxPackStart, boxNew, Container(..), containerAdd,
        infoBarGetContentArea, labelNew, infoBarNew)
import GI.Gtk.Enums
       (FileChooserAction(..), WindowPosition(..), ResponseType(..),
        ButtonsType(..), MessageType(..), ShadowType(..), PolicyType(..),
        Orientation(..))
import GI.Gtk.Flags (TextSearchFlags(..))
import GI.Gtk.Interfaces.FileChooser
       (fileChooserGetFilename, fileChooserSelectFilename,
        fileChooserSetAction)
import GI.Gtk.Objects.Clipboard (clipboardGet)
import GI.Gtk.Objects.Dialog
       (dialogRun, constructDialogUseHeaderBar)
import GI.Gtk.Objects.FileChooserDialog (FileChooserDialog(..))
import GI.Gtk.Objects.MessageDialog
       (setMessageDialogText, constructMessageDialogButtons, setMessageDialogMessageType,
        MessageDialog(..))
import GI.Gtk.Objects.Notebook
       (Notebook(..))
import qualified GI.Gtk.Objects.Notebook as Gtk (Notebook(..))
import GI.Gtk.Objects.ScrolledWindow
       (setScrolledWindowShadowType, scrolledWindowSetPolicy)
import GI.Gtk.Objects.Widget
       (widgetShow, widgetDestroy)
import GI.Gtk.Objects.Window
       (setWindowTitle, setWindowWindowPosition, windowSetTransientFor)
import qualified GI.Gtk.Objects.Window as Gtk (Window(..))

import Graphics.UI.Editor.Parameters
       (dialogRun', dialogSetDefaultResponse', dialogAddButton')
import Graphics.UI.Frame.Panes (IDEPane(..))
import Graphics.UI.Frame.Rectangle (getRectangleY, getRectangleX)

import IDE.Core.State
       (Log, MonadIDE, IDEM, IDEAction, Descr, PackModule, Location(..),
        GenScope(..), PackScope(..), LogRefType(..), LogRef(..),
        CandyTable, Prefs, IDEEvent(..), IDEState(..), autoLoad, Project,
        IDEPackage, liftIDE, readIDE, candy, triggerBuild,
        triggerEventIDE_, SensitivityMask(..), ideMessage,
        MessageLevel(..), __, dscMbModu, dscMbLocation, pack,
        pdMbSourcePath, mdModuleId, pdModules, mdMbSourcePath, dscName,
        modifyIDE_, logRefFullFilePath, contextRefs, srcSpanStartColumn,
        srcSpanStartLine, srcSpanEndColumn, srcSpanEndLine, prefs,
        candyState, textEditorType, textviewFont, unpackDirectory,
        showLineNumbers, rightMargin, tabWidth, wrapLines, sysMessage,
        SrcSpan(..), currentState, reflectIDE, StatusbarCompartment(..),
        SymbolEvent(..), forceLineEnds, removeTBlanks, reifyIDE,
        ipdPackageDir, activePack, workspace, wsPackages, recentFiles,
        addLogRef', belongsToPackage, belongsToPackages,
        belongsToWorkspace, removeLintLogRefs', removeTestLogRefs',
        removeBuildLogRefs', removeFileExtLogRefs', removeLogRefs')
import IDE.Gtk.State
       (PanePath, Connections, IDEGtkEvent(..), getPanes,
        postAsyncIDEIdle, activateThisPane, getBestPathForId,
        paneFromName, getNotebook, figureOutPaneName, buildThisPane,
        paneName, getMainWindow, getActivePanePath, getTopWidget,
        markLabel, guiPropertiesFromName, closeThisPane,
        isStartingOrClosing, RecoverablePane(..))
import qualified IDE.Command.Print as Print
import IDE.Utils.GUIUtils (showDialog, showErrorDialog)
import IDE.Utils.FileUtils (isSubPath, myCanonicalizePath)
import IDE.Utils.DirectoryUtils (setModificationTimeOnOSX)
import IDE.Gtk.SourceCandy
       (stringToCandy, positionFromCandy, getCandylessPart,
        positionToCandy, getCandylessText)
import IDE.SymbolNavigation
       (createHyperLinkSupport, mapControlCommand)
import IDE.Completion as Completion (complete,cancel, smartIndent)
import IDE.TextEditor
       (newDefaultBuffer, newCMBuffer, newYiBuffer, newGtkBuffer,
        TextEditor(..), EditorBuffer, EditorView, EditorIter,
        scrollToCursor, updateStyle)
import IDE.Metainfo.Provider (getSystemInfo, getWorkspaceInfo)
import IDE.BufferMode
       (recentSourceBuffers, selectedModuleName, editKeystrokeCandy,
        editFromCandy, editToCandy, editUncomment, editComment,
        editReformat, Mode(..), getStartAndEndLineOfSelection,
        doForSelectedLines, inBufContext, inActiveBufContext',
        isHaskellMode, modeFromFileName, lastActiveBufferPane,
        inActiveBufContext, maybeActiveBuf, IDEBuffer(..), BufferState(..))
import IDE.Utils.DebugUtils (traceTimeTaken)

--time name action = do
--  liftIO . debugM "leksah" $ name <> " start"
--  start <- liftIO $ realToFrac <$> getPOSIXTime
--  result <- action
--  end <- liftIO $ realToFrac <$> getPOSIXTime
--  liftIO . debugM "leksah" $ name <> " took " <> show ((end - start) * 1000000) <> "us"
--  return result

allBuffers :: MonadIDE m => m [IDEBuffer]
allBuffers = liftIDE getPanes

instance RecoverablePane IDEBuffer BufferState IDEM where
    saveState p@IDEBuffer{sourceView = v} = do
                            buf    <- getBuffer v
                            ins    <- getInsertMark buf
                            iter   <- getIterAtMark buf ins
                            offset <- getOffset iter
                            case fileName p of
                                Nothing ->  do
                                    ct      <-  readIDE candy
                                    text    <-  getCandylessText ct buf
                                    return (Just (BufferStateTrans (bufferName p) text offset))
                                Just fn ->  return (Just (BufferState fn offset))
    recoverState pp (BufferState n i) =   do
        mbbuf    <-  newTextBuffer pp (T.pack $ takeFileName n) (Just n)
        case mbbuf of
            Just IDEBuffer {sourceView=v} -> do
                postAsyncIDEIdle $ do
                    liftIO $ debugM "leksah" "SourceBuffer recoverState idle callback"
                    gtkBuf  <- getBuffer v
                    iter    <- getIterAtOffset gtkBuf i
                    placeCursor gtkBuf iter
                    mark    <- getInsertMark gtkBuf
                    scrollToMark v mark 0.0 (Just (1.0,0.3))
                    liftIO $ debugM "leksah" "SourceBuffer recoverState done"
                return mbbuf
            Nothing -> return Nothing
    recoverState pp (BufferStateTrans bn text i) =   do
        mbbuf    <-  newTextBuffer pp bn Nothing
        case mbbuf of
            Just buf@IDEBuffer{sourceView = v} -> do
                postAsyncIDEIdle $ do
                    liftIO $ debugM "leksah" "SourceBuffer recoverState idle callback"
                    useCandy <- useCandyFor buf
                    gtkBuf   <-  getBuffer v
                    setText gtkBuf text
                    when useCandy $ modeTransformToCandy (mode buf)
                                        (modeEditInCommentOrString (mode buf)) gtkBuf
                    iter     <-  getIterAtOffset gtkBuf i
                    placeCursor gtkBuf iter
                    mark     <-  getInsertMark gtkBuf
                    scrollToMark v mark 0.0 (Just (1.0,0.3))
                    liftIO $ debugM "leksah" "SourceBuffer recoverState done"
                return (Just buf)
            Nothing -> return Nothing
    makeActive actbuf@IDEBuffer{sourceView = sv} = do
        eBuf    <- getBuffer sv
        writeCursorPositionInStatusbar sv
        writeOverwriteInStatusbar sv
        ids1 <- eBuf `afterModifiedChanged` markActiveLabelAsChanged
        ids2 <- sv `afterMoveCursor` writeCursorPositionInStatusbar sv
        -- ids3 <- sv `onLookupInfo` selectInfo sv       -- obsolete by hyperlinks
        ids4 <- sv `afterToggleOverwrite`  writeOverwriteInStatusbar sv
        ids5 <- eBuf `afterChanged` do
            tb <- readIDE triggerBuild
            void . liftIO $ tryPutMVar tb ()
        activateThisPane actbuf $ concat [ids1, ids2, ids4, ids5]
        triggerEventIDE_ (Sensitivity [(SensitivityEditor, True)])
        grabFocus sv
        void $ checkModTime actbuf
    closePane pane = do makeActive pane
                        fileClose
    buildPane _panePath _notebook _builder = return Nothing
    builder _pp _nb _w =    return (Nothing,[])

startComplete :: IDEAction
startComplete = do
    mbBuf <- maybeActiveBuf
    case mbBuf of
        Nothing     -> return ()
        Just IDEBuffer{sourceView = v} -> complete v True

findSourceBuf :: MonadIDE m => FilePath -> m [IDEBuffer]
findSourceBuf fp = do
    fpc <- liftIO $ myCanonicalizePath fp
    filter (maybe False (equalFilePath fpc) . fileName) <$> allBuffers

selectSourceBuf :: MonadIDE m => FilePath -> m (Maybe IDEBuffer)
selectSourceBuf fp =
    findSourceBuf fp >>= \case
        hdb:_ -> liftIDE $ do
            makeActive hdb
            return (Just hdb)
        _ -> liftIDE $ do
            fpc <- liftIO $ myCanonicalizePath fp
            fe <- liftIO $ doesFileExist fpc
            if fe
                then do
                    pp      <- getBestPathForId  "*Buffer"
                    liftIO $ debugM "lekash" "selectSourceBuf calling newTextBuffer"
                    nbuf <- newTextBuffer pp (T.pack $ takeFileName fpc) (Just fpc)
                    liftIO $ debugM "lekash" "selectSourceBuf newTextBuffer returned"
                    return nbuf
                else do
                    ideMessage Normal (__ "File path not found " <> T.pack fpc)
                    return Nothing

goToDefinition :: Descr -> IDEAction
goToDefinition idDescr = goToLocation (dscMbModu idDescr) (dscMbLocation idDescr)

goToLocation :: Maybe PackModule -> Maybe Location -> IDEAction
goToLocation mbMod mbLoc = do

    mbWorkspaceInfo     <-  getWorkspaceInfo
    mbSystemInfo        <-  getSystemInfo
    let mbPackagePath = (mbWorkspaceInfo >>= (packagePathFromScope . fst))
                        <|> (mbSystemInfo >>= packagePathFromScope)
        mbSourcePath = (mbWorkspaceInfo  >>= (sourcePathFromScope . fst))
                        <|> (mbSystemInfo >>= sourcePathFromScope)

    liftIO . debugM "leksah" $ show (mbPackagePath, mbLoc, mbSourcePath)
    case (mbPackagePath, mbLoc, mbSourcePath) of
        (Just packagePath, Just loc, _) -> void (goToSourceDefinition (dropFileName packagePath) loc)
        (_, Just loc, Just sourcePath)  -> void (goToSourceDefinition' sourcePath loc)
        (_, _, Just sp) -> void (selectSourceBuf sp)
        _  -> return ()
  where
    packagePathFromScope :: GenScope -> Maybe FilePath
    packagePathFromScope (GenScopeC (PackScope l _)) =
        case mbMod of
            Just mod' -> case pack mod' `Map.lookup` l of
                            Just pack -> pdMbSourcePath pack
                            Nothing   -> Nothing
            Nothing -> Nothing

    sourcePathFromScope :: GenScope -> Maybe FilePath
    sourcePathFromScope (GenScopeC (PackScope l _)) =
        case mbMod of
            Just mod' -> case pack mod' `Map.lookup` l of
                            Just pack ->
                                case filter (\md -> mdModuleId md == mod')
                                                    (pdModules pack) of
                                    (mod'' : _) ->  mdMbSourcePath mod''
                                    []         -> Nothing
                            Nothing -> Nothing
            Nothing -> Nothing

goToSourceDefinition :: FilePath -> Location -> IDEM (Maybe IDEBuffer)
goToSourceDefinition packagePath loc =
    goToSourceDefinition' (packagePath </> locationFile loc) loc

goToSourceDefinition' :: FilePath -> Location -> IDEM (Maybe IDEBuffer)
goToSourceDefinition' sourcePath Location{..} = do
    mbBuf     <- selectSourceBuf sourcePath
    case mbBuf of
        Just _ ->
            inActiveBufContext () $ \sv ebuf _ -> do
                liftIO $ debugM "lekash" "goToSourceDefinition calculating range"
                lines'          <-  getLineCount ebuf
                iterTemp        <-  getIterAtLine ebuf (max 0 (min (lines'-1)
                                        (locationSLine -1)))
                chars           <-  getCharsInLine iterTemp
                iter <- atLineOffset iterTemp (max 0 (min (chars-1) (locationSCol -1)))
                iter2Temp       <-  getIterAtLine ebuf (max 0 (min (lines'-1) (locationELine -1)))
                chars2          <-  getCharsInLine iter2Temp
                iter2 <- atLineOffset iter2Temp (max 0 (min (chars2-1) locationECol))
                -- ### we had a problem before using postAsyncIDEIdle
                postAsyncIDEIdle $ do
                    liftIO $ debugM "lekash" "goToSourceDefinition triggered selectRange"
                    selectRange ebuf iter iter2
                    liftIO $ debugM "lekash" "goToSourceDefinition triggered scrollToIter"
                    scrollToIter sv iter 0.0 (Just (1.0,0.3))
                return ()
        Nothing -> return ()
    return mbBuf

insertInBuffer :: Descr -> IDEAction
insertInBuffer idDescr = do
    mbPaneName <- lastActiveBufferPane
    case mbPaneName of
        Nothing  -> return ()
        Just name -> do
            PaneC p <- paneFromName name
            let mbBuf = cast p
            case mbBuf of
                Nothing -> return ()
                Just IDEBuffer{sourceView = v} -> do
                    ebuf <- getBuffer v
                    mark <- getInsertMark ebuf
                    iter <- getIterAtMark ebuf mark
                    insert ebuf iter (dscName idDescr)

updateStyle' :: IDEBuffer -> IDEAction
updateStyle' IDEBuffer {sourceView = sv} = getBuffer sv >>= updateStyle

removeFromBuffers :: Map FilePath [LogRefType] -> IDEAction
removeFromBuffers removeDetails = do
    buffers <- allBuffers
    let matchingBufs = filter (maybe False (`Map.member` removeDetails) . fileName) buffers
    F.forM_ matchingBufs $ \ IDEBuffer {..} -> do
        buf <- getBuffer sourceView
        F.forM_ (maybe [] (fromMaybe [] . (`Map.lookup` removeDetails)) fileName) $
            removeTagByName buf . T.pack . show

removeLogRefs :: (Log -> FilePath -> Bool) -> [LogRefType] -> IDEAction
removeLogRefs toRemove' types =
  removeLogRefs' toRemove' types removeFromBuffers

--removeFileLogRefs :: FilePath -> [LogRefType] -> IDEAction
--removeFileLogRefs file types =
--  removeFileLogRefs' file types removeFromBuffers

removeFileExtLogRefs :: Log -> String -> [LogRefType] -> IDEAction
removeFileExtLogRefs log' fileExt types =
  removeFileExtLogRefs' log' fileExt types removeFromBuffers

--removePackageLogRefs :: Log -> [LogRefType] -> IDEAction
--removePackageLogRefs log' types =
--  removePackageLogRefs' log' types removeFromBuffers

removeBuildLogRefs :: FilePath -> IDEAction
removeBuildLogRefs file =
  removeBuildLogRefs' file removeFromBuffers

removeTestLogRefs :: Log -> IDEAction
removeTestLogRefs log' =
  removeTestLogRefs' log' removeFromBuffers

removeLintLogRefs :: FilePath -> IDEAction
removeLintLogRefs file =
  removeLintLogRefs' file removeFromBuffers

addLogRef :: Bool -> Bool -> LogRef -> IDEAction
addLogRef hlintFileScope backgroundBuild ref =
    addLogRef' hlintFileScope backgroundBuild ref $ do
        buffers <- allBuffers
        let matchingBufs = filter (maybe False (equalFilePath (logRefFullFilePath ref)) . fileName) buffers
        F.forM_ matchingBufs $ \ buf -> markRefInSourceBuf buf ref False

markRefInSourceBuf :: IDEBuffer -> LogRef -> Bool -> IDEAction
markRefInSourceBuf buf@IDEBuffer{sourceView = sv} logRef scrollTo = traceTimeTaken "markRefInSourceBuf" $ do
    useCandy     <- useCandyFor buf
    candy'       <- readIDE candy
    contextRefs' <- readIDE contextRefs
    ebuf <- getBuffer sv
    let tagName = T.pack $ show (logRefType logRef)
    liftIO . debugM "lekash" . T.unpack $ "markRefInSourceBuf getting or creating tag " <> tagName

    liftIO $ debugM "lekash" "markRefInSourceBuf calculating range"
    let start' = (srcSpanStartLine (logRefSrcSpan logRef),
                    srcSpanStartColumn (logRefSrcSpan logRef))
    let end'   = (srcSpanEndLine (logRefSrcSpan logRef),
                    srcSpanEndColumn (logRefSrcSpan logRef))
    start <- if useCandy
                then positionToCandy candy' ebuf start'
                else return start'
    end   <- if useCandy
                then positionToCandy candy' ebuf end'
                else return end'
    lines'  <-  getLineCount ebuf
    iterTmp <-  getIterAtLine ebuf (max 0 (min (lines'-1) (fst start - 1)))
    chars   <-  getCharsInLine iterTmp
    iter    <- atLineOffset iterTmp (max 0 (min (chars-1) (snd start)))

    iter2 <- if start == end
        then do
            maybeWE <- forwardWordEndC iter
            case maybeWE of
                Nothing -> atEnd iter
                Just we -> return we
        else do
            newTmp  <- getIterAtLine ebuf (max 0 (min (lines'-1) (fst end - 1)))
            chars'  <- getCharsInLine newTmp
            new     <- atLineOffset newTmp (max 0 (min (chars'-1) (snd end)))
            forwardCharC new

    let last' (Seq.viewr -> EmptyR)  = Nothing
        last' (Seq.viewr -> _xs :> x) = Just x
        last' _                      = Nothing
        latest = last' contextRefs'
        isOldContext = case (logRefType logRef, latest) of
                            (ContextRef, Just ctx) | ctx /= logRef -> True
                            _ -> False
    unless isOldContext $ do
        liftIO $ debugM "lekash" "markRefInSourceBuf calling applyTagByName"
        traceTimeTaken "createMark" $ createMark sv (logRefType logRef) iter . T.unlines
            . zipWith ($) (replicate 30 id <> [const "..."]) . T.lines $ refDescription logRef
        traceTimeTaken "applyTagByName" $ applyTagByName ebuf tagName iter iter2
    when scrollTo $ do
        liftIO $ debugM "lekash" "markRefInSourceBuf triggered placeCursor"
        placeCursor ebuf iter
        mark <- getInsertMark ebuf
        liftIO $ debugM "lekash" "markRefInSourceBuf trigged scrollToMark"
        scrollToMark sv mark 0.3 Nothing
        when isOldContext $ selectRange ebuf iter iter2

unmarkRefInSourceBuf :: IDEBuffer -> LogRef -> IDEAction
unmarkRefInSourceBuf IDEBuffer {sourceView = sv} logRef = do
    buf     <-  getBuffer sv
    removeTagByName buf (T.pack $ show (logRefType logRef))


-- | Tries to create a new text buffer, fails when the given filepath
-- does not exist or when it is not a text file.
newTextBuffer :: PanePath -> Text -> Maybe FilePath -> IDEM (Maybe IDEBuffer)
newTextBuffer panePath bn mbfn =
     case mbfn of
            Nothing -> buildPane' "" Nothing
            Just fn ->
                do eErrorContents <- liftIO $
                                         catch (Right <$> T.readFile fn)
                                               (\e -> return $ Left (show (e :: IOError)))
                   case eErrorContents of
                       Right contents -> do
                           modTime  <- liftIO $ getModificationTime fn
                           buildPane' contents (Just modTime)
                       Left err       -> do
                           ideMessage Normal (__ "Error reading file " <> T.pack err)
                           return Nothing

    where buildPane' contents mModTime = do
            nb      <-  getNotebook panePath
            prefs'  <-  readIDE prefs
            let useCandy = candyState prefs'
            ct      <-  readIDE candy
            (ind,rbn) <- figureOutPaneName bn
            buildThisPane panePath nb (builder' useCandy mbfn ind bn rbn ct prefs' contents mModTime)

data CharacterCategory = IdentifierCharacter | SpaceCharacter | SyntaxCharacter
    deriving (Eq)
getCharacterCategory :: Maybe Char -> CharacterCategory
getCharacterCategory Nothing = SpaceCharacter
getCharacterCategory (Just c)
    | isAlphaNum c || c == '\'' || c == '_' = IdentifierCharacter
    | isSpace c = SpaceCharacter
    | otherwise = SyntaxCharacter

builder' :: Bool ->
    Maybe FilePath ->
    Int ->
    Text ->
    Text ->
    CandyTable ->
    Prefs ->
    Text  ->
    Maybe UTCTime ->
    PanePath ->
    Gtk.Notebook ->
    Gtk.Window ->
    IDEM (Maybe IDEBuffer,Connections)
builder' useCandy mbfn ind bn _rbn _ct prefs' fileContents modTime _pp _nb _windows =
    case textEditorType prefs' of
        "GtkSourceView" -> newGtkBuffer mbfn fileContents >>= makeBuffer
        "Yi"            -> newYiBuffer mbfn fileContents >>= makeBuffer
        "CodeMirror"    -> newCMBuffer mbfn fileContents >>= makeBuffer
        _               -> newDefaultBuffer mbfn fileContents >>= makeBuffer

  where
    makeBuffer :: TextEditor editor => EditorBuffer editor -> IDEM (Maybe IDEBuffer,Connections)
    makeBuffer buffer = do
        liftIO $ debugM "lekash" "makeBuffer"
        ideR <- ask

        beginNotUndoableAction buffer
        let mode = modeFromFileName mbfn
        when (useCandy && isHaskellMode mode) $ modeTransformToCandy mode
                                                    (modeEditInCommentOrString mode) buffer
        endNotUndoableAction buffer
        setModified buffer False
        siter <- getStartIter buffer
        placeCursor buffer siter

        -- create a new SourceView Widget
        (sv, sw, grid) <- newViewWithMap buffer (textviewFont prefs')

        -- Files opened from the unpackDirectory are meant for documentation
        -- and are not actually a source dependency, they should not be editable.
        homeDir <- liftIO getHomeDirectory
        let isEditable = fromMaybe True $ do
                            dir  <- unpackDirectory prefs'
                            let expandedDir = case dir of
                                    '~':rest -> homeDir ++ rest
                                    rest -> rest
                            file <- mbfn
                            return (not $ splitDirectories expandedDir `isPrefixOf` splitDirectories file)

        setEditable sv isEditable
        setShowLineNumbers sv $ showLineNumbers prefs'
        setRightMargin sv $ case rightMargin prefs' of
                                (False,_) -> Nothing
                                (True,v) -> Just v
        setIndentWidth sv $ tabWidth prefs'
        setTabWidth sv 8 -- GHC treats tabs as 8 we should display them that way
        drawTabs sv
        updateStyle buffer

        if wrapLines prefs'
            then scrolledWindowSetPolicy sw PolicyTypeNever PolicyTypeAutomatic
            else scrolledWindowSetPolicy sw PolicyTypeAutomatic PolicyTypeAutomatic
        liftIO $ debugM "lekash" "makeBuffer setScrolledWindowShadowType"
        setScrolledWindowShadowType sw ShadowTypeIn
        liftIO $ debugM "lekash" "makeBuffer setScrolledWindowShadowType done"


        box <- boxNew OrientationVertical 0
        unless isEditable $ liftIO $ do
            bar <- infoBarNew
            lab <- labelNew (Just "This file is opened in read-only mode because it comes from a non-local package")
            area <- infoBarGetContentArea bar >>= unsafeCastTo Container
            containerAdd area lab
            -- infoBarAddButton bar "Enable editing" (fromIntegral . fromEnum $ ResponseTypeReject)
            -- infoBarSetShowCloseButton bar True
            boxPackStart box bar False False 0
            widgetShow bar

        boxPackStart box grid True True 0

        reloadDialog <- liftIO $ newMVar Nothing

        modTimeRef <- liftIO $ newIORef modTime
        modifiedOnDiskRef <- liftIO $ newIORef False
        let buf = IDEBuffer {
            fileName =  mbfn,
            bufferName = bn,
            addedIndex = ind,
            sourceView =sv,
            vBox = box,
            modTime = modTimeRef,
            modifiedOnDisk = modifiedOnDiskRef,
            mode = mode,
            reloadDialog = reloadDialog}
        -- events
        ids1 <- afterFocusIn sv $ makeActive buf
        ids2 <- onCompletion sv (Completion.complete sv False) Completion.cancel
        ids3 <- onButtonPress sv $ do
                e <- lift ask
                click <- getEventButtonType e
                liftIDE $
                    case click of
                        EventType2buttonPress -> do
                            (start, end) <- getIdentifierUnderCursor buffer
                            selectRange buffer start end
                            return True
                        _ -> return False

        (GtkEvent (GetTextPopup mbTpm)) <- triggerEvent ideR (GtkEvent $ GetTextPopup Nothing)
        ids4 <- case mbTpm of
            Just tpm    -> sv `onPopulatePopup` \menu -> liftIO $ tpm ideR menu
            Nothing     -> do
                sysMessage Normal "SourceBuffer>> no text popup"
                return []

        hasMatch <- liftIO $ newIORef False
        ids5 <- onSelectionChanged buffer $ do
            (iStart, iEnd) <- getSelectionBounds buffer
            lStart <- (+1) <$> getLine iStart
            cStart <- getLineOffset iStart
            lEnd <- (+1) <$> getLine iEnd
            cEnd <- getLineOffset iEnd
            triggerEventIDE_ . SelectSrcSpan $
                case mbfn of
                    Just fn -> Just (SrcSpan fn lStart cStart lEnd cEnd)
                    Nothing -> Nothing

            let tagName = "selection-match"
            hasSel <- hasSelection buffer
            m <- liftIO $ readIORef hasMatch
            when m $ removeTagByName buffer tagName
            r <- if hasSel
                    then do
                        candy'    <- readIDE candy
                        sTxt      <- getCandylessPart candy' buffer iStart iEnd
                        let strippedSTxt = T.strip sTxt
                        if T.null strippedSTxt
                            then return False
                            else do
                                bi1 <- getStartIter buffer
                                bi2 <- getEndIter buffer
                                r1 <- forwardApplying bi1 strippedSTxt (Just iStart) tagName buffer
                                r2 <- forwardApplying iEnd strippedSTxt (Just bi2) tagName buffer
                                return (r1 || r2)
                    else return False
            liftIO $ writeIORef hasMatch r
            return ()

        ids6 <- onKeyPress sv $ do
            e        <- lift ask
            keyval   <- getEventKeyKeyval e
            name     <- keyvalName keyval
            modifier <- getEventKeyState e
            liftIDE $ do
                let moveToNextWord iterOp sel  = do
                        sel' <- iterOp sel
                        rs <- isRangeStart sel'
                        if rs then return sel' else moveToNextWord iterOp sel'
                let calculateNewPosition iterOp = getInsertIter buffer >>= moveToNextWord iterOp
                let continueSelection keepSelBound nsel = do
                        if keepSelBound
                            then do
                                sb <- getSelectionBoundMark buffer >>= getIterAtMark buffer
                                selectRange buffer nsel sb
                            else
                                placeCursor buffer nsel
                        scrollToIter sv nsel 0 Nothing
                case (name, map mapControlCommand modifier, keyval) of
                    (Just "Left",[ModifierTypeControlMask],_) -> do
                        calculateNewPosition backwardCharC >>= continueSelection False
                        return True
                    (Just "Left",[ModifierTypeShiftMask, ModifierTypeControlMask],_) -> do
                        calculateNewPosition backwardCharC >>= continueSelection True
                        return True
                    (Just "Right",[ModifierTypeControlMask],_) -> do
                        calculateNewPosition forwardCharC >>= continueSelection False --placeCursor buffer
                        return True
                    (Just "Right",[ModifierTypeControlMask, ModifierTypeControlMask],_) -> do
                        calculateNewPosition forwardCharC >>= continueSelection True
                        return True
                    (Just "BackSpace",[ModifierTypeControlMask],_) -> do              -- delete word
                        here <- getInsertIter buffer
                        there <- calculateNewPosition backwardCharC
                        delete buffer here there
                        return True
                    (Just "underscore",[ModifierTypeControlMask, ModifierTypeControlMask],_) -> do
                        selectInfo buf buffer sv True False
                        return True
                        -- Redundant should become a go to definition directly
                    (Just "minus",[ModifierTypeControlMask],_) -> do
                        selectInfo buf buffer sv True True
                        return True
                    (Just "Return", [], _) ->
                        readIDE currentState >>= \case
                            IsCompleting _ -> return False
                            _              -> smartIndent sv >> return True
                    -- Avoid passing these directly to bindinsActivateEvent because that seems
                    -- to hide them from the auto complete code (well up and down anyway)
                    (Just key, _, _) | key `elem`
                        ["Tab", "Return", "Down", "Up", "BackSpace"
                        ,"Shift_L", "Shift_R", "Super_L", "Super_R"] -> return False
                    _ -> do
                        w <- getEditorWidget sv
                        bindingsActivateEvent w e
        ids7 <-
            createHyperLinkSupport sv sw
                (\ctrl _shift iter -> do
                    (beg, en) <- getIdentifierUnderCursorFromIter (iter, iter)
                    when ctrl $ selectInfo' buf buffer sv beg en False False
                    return (beg, if ctrl then en else beg))
                (\_ _shift (beg, en) -> selectInfo' buf buffer sv beg en True True)
        return (Just buf,concat [ids1, ids2, ids3, ids4, ids5, ids6, ids7])

    forwardApplying :: TextEditor editor
                    => EditorIter editor
                    -> Text   -- txt
                    -> Maybe (EditorIter editor)
                    -> Text   -- tagname
                    -> EditorBuffer editor
                    -> IDEM Bool
    forwardApplying tI txt mbTi tagName ebuf = do
        mbFTxt <- forwardSearch tI txt [TextSearchFlagsVisibleOnly, TextSearchFlagsTextOnly] mbTi
        case mbFTxt of
            Just (start, end) -> do
                startsW <- startsWord start
                endsW <- endsWord end
                when (startsW && endsW) $
                    applyTagByName ebuf tagName start end
                (|| (startsW && endsW)) <$> forwardApplying end txt mbTi tagName ebuf
            Nothing -> return False

isRangeStart
  :: TextEditor editor
  => EditorIter editor
  -> IDEM Bool
isRangeStart sel = do                                   -- if char and previous char are of different char categories
    currentChar <- getChar sel
    let mbStartCharCat = getCharacterCategory currentChar
    mbPrevCharCat <- getCharacterCategory <$> (backwardCharC sel >>= getChar)
    return $ isNothing currentChar || currentChar == Just '\n' || mbStartCharCat /= mbPrevCharCat && (mbStartCharCat == SyntaxCharacter || mbStartCharCat == IdentifierCharacter)

-- | Get an iterator pair (start,end) delimiting the identifier currently under the cursor
getIdentifierUnderCursor :: forall editor. TextEditor editor => EditorBuffer editor -> IDEM (EditorIter editor, EditorIter editor)
getIdentifierUnderCursor buffer = do
    (startSel, endSel) <- getSelectionBounds buffer
    getIdentifierUnderCursorFromIter (startSel, endSel)

-- | Get an iterator pair (start,end) delimiting the identifier currently contained inside the provided iterator pair
getIdentifierUnderCursorFromIter :: TextEditor editor => (EditorIter editor, EditorIter editor) -> IDEM (EditorIter editor, EditorIter editor)
getIdentifierUnderCursorFromIter (startSel, endSel) = do
    let isIdent a = isAlphaNum a || a == '\'' || a == '_'
    let isOp    a = isSymbol   a || a == ':'  || a == '\\' || a == '*' || a == '/' || a == '-'
                                 || a == '!'  || a == '@' || a == '%' || a == '&' || a == '?'
    mbStartChar <- getChar startSel
    mbEndChar <- getChar endSel
    let isSelectChar =
            case mbStartChar of
                Just startChar | isIdent startChar -> \a -> isIdent a || a == '.'
                Just startChar | isOp    startChar -> isOp
                _                                  -> const False
    start <- case mbStartChar of
        Just startChar | isSelectChar startChar -> do
            maybeIter <- backwardFindCharC startSel (not.isSelectChar) Nothing
            case maybeIter of
                Just iter -> forwardCharC iter
                Nothing   -> return startSel
        _ -> return startSel
    end <- case mbEndChar of
        Just endChar | isSelectChar endChar -> do
            maybeIter <- forwardFindCharC endSel (not.isSelectChar) Nothing
            case maybeIter of
                Just iter -> return iter
                Nothing   -> return endSel
        _ -> return endSel
    return (start, end)

setModifiedOnDisk :: MonadIDE m => FilePath -> m Bool
setModifiedOnDisk fp = do
    bufs <- findSourceBuf fp
    forM_ bufs $ \buf ->
        liftIO $ writeIORef (modifiedOnDisk buf) True
    return . not $ null bufs

checkModTime :: MonadIDE m => IDEBuffer -> m Bool
checkModTime buf = do
  currentState' <- readIDE currentState
  case  currentState' of
    IsShuttingDown -> return False
    _              ->
      liftIO (readIORef (modifiedOnDisk buf)) >>= \case
        False -> return False
        True  -> do
            liftIO $ writeIORef (modifiedOnDisk buf) False
            let name = paneName buf
            case fileName buf of
                Just fn -> do
                    exists <- liftIO $ doesFileExist fn
                    if exists
                        then do
                            nmt <- liftIO $ getModificationTime fn
                            modTime' <- liftIO $ readIORef (modTime buf)
                            case modTime' of
                                Nothing ->  error $"checkModTime: time not set " ++ show (fileName buf)
                                Just mt ->
                                    if nmt /= mt -- Fonts get messed up under windows when adding this line.
                                                  -- Praises to whoever finds out what happens and how to fix this
                                    then do
                                        load <- readIDE (prefs . to autoLoad)
                                        if load
                                            then do
                                                ideMessage Normal $ __ "Auto Loading " <> T.pack fn
                                                revert buf
                                                return True
                                            else
                                                liftIO (takeMVar $ reloadDialog buf) >>= \case
                                                    Just md -> do
                                                        liftIO $ putMVar (reloadDialog buf) (Just md)
                                                        return True
                                                    Nothing -> do
                                                        window <- liftIDE getMainWindow
                                                        md <- new' MessageDialog [
                                                            constructDialogUseHeaderBar 0,
                                                            constructMessageDialogButtons ButtonsTypeNone]
                                                        liftIO $ putMVar (reloadDialog buf) (Just md)
                                                        setMessageDialogMessageType md MessageTypeQuestion
                                                        setMessageDialogText md (__ "File \"" <> name <> __ "\" has changed on disk.")
                                                        windowSetTransientFor md (Just window)
                                                        _ <- dialogAddButton' md (__ "_Load From Disk") (AnotherResponseType 1)
                                                        _ <- dialogAddButton' md (__ "_Always Load From Disk") (AnotherResponseType 2)
                                                        _ <- dialogAddButton' md (__ "_Don't Load") (AnotherResponseType 3)
                                                        dialogSetDefaultResponse' md (AnotherResponseType 1)
                                                        setWindowWindowPosition md WindowPositionCenterOnParent
                                                        widgetShowAll md
                                                        ideR <- liftIDE ask
                                                        _ <- onDialogResponse md $ \n32 -> (`reflectIDE` ideR) $ do
                                                            liftIO $ modifyMVar_ (reloadDialog buf) . const $ return Nothing
                                                            widgetDestroy md
                                                            case toEnum (fromIntegral n32) of
                                                                AnotherResponseType 1 ->
                                                                    revert buf
                                                                AnotherResponseType 2 -> do
                                                                    revert buf
                                                                    modifyIDE_ $ prefs %~ (\p -> p {autoLoad = True})
                                                                AnotherResponseType 3 -> dontLoad fn
                                                                ResponseTypeDeleteEvent -> dontLoad fn
                                                                _ -> return ()
                                                        return True

                                    else return False
                        else return False
                Nothing -> return False
    where
        dontLoad fn = do
            nmt2 <- liftIO $ getModificationTime fn
            liftIO $ writeIORef (modTime buf) (Just nmt2)

setModTime :: IDEBuffer -> IDEAction
setModTime buf =
    case fileName buf of
        Nothing -> return ()
        Just fn -> liftIO $ E.catch
            (do
                nmt <- getModificationTime fn
                writeIORef (modTime buf) (Just nmt))
            (\(e:: SomeException) -> do
                sysMessage Normal (T.pack $ show e)
                return ())

fileRevert :: IDEAction
fileRevert = inActiveBufContext () $ \_ _ currentBuffer ->
    revert currentBuffer

revert :: MonadIDE m => IDEBuffer -> m ()
revert buf@IDEBuffer{sourceView = sv} = do
    useCandy    <-  useCandyFor buf
    case fileName buf of
        Nothing -> return ()
        Just fn -> liftIDE $ do
            buffer <- getBuffer sv
            fc <- liftIO $ readFile fn
            mt <- liftIO $ getModificationTime fn
            beginNotUndoableAction buffer
            setText buffer $ T.pack fc
            when useCandy $
                modeTransformToCandy (mode buf)
                    (modeEditInCommentOrString (mode buf))
                    buffer
            endNotUndoableAction buffer
            setModified buffer False
            liftIO $ writeIORef (modTime buf) (Just mt)

writeCursorPositionInStatusbar :: TextEditor editor => EditorView editor -> IDEAction
writeCursorPositionInStatusbar sv = do
    buf  <- getBuffer sv
    mark <- getInsertMark buf
    iter <- getIterAtMark buf mark
    line <- getLine iter
    col  <- getLineOffset iter
    triggerEventIDE_ (StatusbarChanged [CompartmentBufferPos (line,col)])
    return ()

writeOverwriteInStatusbar :: TextEditor editor => EditorView editor -> IDEAction
writeOverwriteInStatusbar sv = do
    mode <- getOverwrite sv
    triggerEventIDE_ (StatusbarChanged [CompartmentOverlay mode])
    return ()

selectInfo' :: TextEditor e => IDEBuffer -> EditorBuffer e -> EditorView e -> EditorIter e -> EditorIter e -> Bool -> Bool -> IDEAction
selectInfo' buf ebuf view start end activatePanes gotoSource = do
    candy' <- readIDE candy
    sTxt   <- getCandylessPart candy' ebuf start end
    startPos <- getLocation buf ebuf start
    endPos <- getLocation buf ebuf end
    unless (T.null sTxt) $ do
        rect <- getIterLocation view end
        bx   <- getRectangleX rect
        by   <- getRectangleY rect
        (x, y) <- bufferToWindowCoords view (fromIntegral bx, fromIntegral by)
        getWindow view >>= \case
            Nothing -> return ()
            Just drawWindow -> do
                (_, ox, oy)  <- windowGetOrigin drawWindow
                triggerEventIDE_ (SelectInfo (SymbolEvent sTxt ((, startPos, endPos) <$> fileName buf) activatePanes gotoSource (ox + fromIntegral x, oy + fromIntegral y)))

selectInfo :: TextEditor e => IDEBuffer -> EditorBuffer e -> EditorView e -> Bool -> Bool -> IDEAction
selectInfo buf ebuf view activatePanes gotoSource = do
    (l,r)   <- getIdentifierUnderCursor ebuf
    selectInfo' buf ebuf view l r activatePanes gotoSource

markActiveLabelAsChanged :: IDEAction
markActiveLabelAsChanged = do
    mbPath <- getActivePanePath
    case mbPath of
        Nothing -> return ()
        Just path -> do
          nb <- getNotebook path
          mbBS <- maybeActiveBuf
          F.forM_ mbBS (markLabelAsChanged nb)

markLabelAsChanged :: Notebook -> IDEBuffer -> IDEAction
markLabelAsChanged nb buf@IDEBuffer{sourceView = sv} = do
    liftIO $ debugM "leksah" "markLabelAsChanged"
    ebuf   <- getBuffer sv
    modified <- getModified ebuf
    w <- getTopWidget buf
    markLabel nb w modified

fileSaveBuffer :: (MonadIDE m, TextEditor editor) => Bool -> Notebook -> EditorView editor -> EditorBuffer editor -> IDEBuffer -> Int -> m Bool
fileSaveBuffer query nb _ ebuf ideBuf@IDEBuffer{sourceView = sv} _i = liftIDE $ do
    window  <- getMainWindow
    prefs'   <- readIDE prefs
    useCandy <- useCandyFor ideBuf
    candy'   <- readIDE candy
    (panePath,_connects) <- guiPropertiesFromName (paneName ideBuf)
    case fileName ideBuf of
      Just fn | not query -> do
        modifiedOnDisk <- checkModTime ideBuf -- The user is given option to reload
        modifiedInBuffer <- getModified ebuf
        if modifiedInBuffer
            then do
                fileSave' (forceLineEnds prefs') (removeTBlanks prefs')
                    useCandy candy' fn
                setModTime ideBuf
                return True
            else return modifiedOnDisk
      mbfn -> reifyIDE $ \ideR   ->  do
        dialog <- new' FileChooserDialog [constructDialogUseHeaderBar 1]
        setWindowTitle dialog (__ "Save File")
        windowSetTransientFor dialog $ Just window
        fileChooserSetAction dialog FileChooserActionSave
        _ <- dialogAddButton' dialog "gtk-cancel" ResponseTypeCancel
        _ <- dialogAddButton' dialog "gtk-save" ResponseTypeAccept
        forM_ mbfn $ fileChooserSelectFilename dialog
        widgetShow dialog
        response <- dialogRun' dialog
        mbFileName <- case response of
                ResponseTypeAccept      -> fileChooserGetFilename dialog
                ResponseTypeCancel      -> return Nothing
                ResponseTypeDeleteEvent -> return Nothing
                _                       -> return Nothing
        widgetDestroy dialog
        case mbFileName of
            Nothing -> return False
            Just fn -> do
                dfe <- doesFileExist fn
                resp <- if dfe
                    then do md <- new' MessageDialog [
                                constructDialogUseHeaderBar 0,
                                constructMessageDialogButtons ButtonsTypeCancel]
                            setMessageDialogMessageType md MessageTypeQuestion
                            setMessageDialogText md $ __ "File already exist."
                            windowSetTransientFor md (Just window)
                            _ <- dialogAddButton' md (__ "_Overwrite") ResponseTypeYes
                            dialogSetDefaultResponse' md ResponseTypeCancel
                            setWindowWindowPosition md WindowPositionCenterOnParent
                            resp <- toEnum . fromIntegral <$> dialogRun md
                            widgetDestroy md
                            return resp
                    else return ResponseTypeYes
                case resp of
                    ResponseTypeYes -> do
                        reflectIDE (do
                            fileSave' (forceLineEnds prefs') (removeTBlanks prefs')
                                useCandy candy' fn
                            _ <- closePane ideBuf
                            cfn <- liftIO $ myCanonicalizePath fn
                            void $ newTextBuffer panePath (T.pack $ takeFileName cfn) (Just cfn)
                            ) ideR
                        return True
                    _          -> return False
    where
        fileSave' :: Bool -> Bool -> Bool -> CandyTable -> FilePath -> IDEAction
        fileSave' _forceLineEnds removeTBlanks _useCandy candyTable fn = do
            buf     <-   getBuffer sv
            text    <-   getCandylessText candyTable buf
            let text' = if removeTBlanks
                            then T.unlines $ map (T.dropWhileEnd $ \c -> c == ' ') $ T.lines text
                            else text
            alreadyExists <- liftIO $ doesFileExist fn
            mbModTimeBefore <- if alreadyExists
                then liftIO $ Just <$> getModificationTime fn
                else return Nothing
            succ' <- liftIO $ E.catch (do T.writeFile fn text'; return True)
                (\(e :: SomeException) -> do
                    sysMessage Normal . T.pack $ show e
                    return False)

            -- Truely horrible hack to work around HFS+ only having 1sec resolution
            -- and ghc ignoring files unless the modifiction time has moved forward.
            -- The limitation means we can do at most 1 reload a second, but
            -- this hack allows us to take an advance of up to 30 reloads (by
            -- moving the modidification time up to 30s into the future).
            modTimeChanged <- liftIO $ case mbModTimeBefore of
                Nothing -> return True
                Just modTime -> do
                    newModTime <- getModificationTime fn
                    let diff = diffUTCTime modTime newModTime
                    if
                        | (newModTime > modTime) -> return True -- All good mode time has moved on
                        | diff < 30 -> do
                             setModificationTimeOnOSX fn (addUTCTime 1 modTime)
                             updatedModTime <- getModificationTime fn
                             return (updatedModTime > modTime)
                        | diff < 32 -> do
                             -- Reached our limit of how far in the future we want to set the modifiction time.
                             -- Using 32 instead of 31 in case NTP or something is adjusting the clock back.
                             warningM "leksah" $ "Modification time for " <> fn
                                <> " was already " <> show (diffUTCTime modTime newModTime)
                                <> " in the future"
                             -- We still want to keep the modification time the same though.
                             -- If it went back the future date ghc has might cause it to
                             -- continue to ignore the file.
                             setModificationTimeOnOSX fn modTime
                             return False
                        | otherwise -> do
                             -- This should never happen unless something else is messing
                             -- with the modification time or the clock.
                             -- If it does happen we will leave the modifiction time alone.
                             errorM "leksah" $ "Modification time for " <> fn
                                <> " was already " <> show (diffUTCTime modTime newModTime)
                                <> " in the future"
                             return True

            -- Only consider the file saved if the modification time changed
            -- otherwise another save is really needed to trigger ghc.
            when modTimeChanged $ do
                setModified buf (not succ')
                markLabelAsChanged nb ideBuf
                triggerEventIDE_ $ SavedFile fn

fileSave :: Bool -> IDEM Bool
fileSave query = inActiveBufContext' False $ fileSaveBuffer query

fileSaveAll :: MonadIDE m => (IDEBuffer -> m Bool) -> m Bool
fileSaveAll filterFunc = do
    bufs     <- allBuffers
    filtered <- filterM filterFunc bufs
    modified <- filterM fileCheckBuffer filtered
    results  <- forM modified (\buf -> inBufContext False buf (fileSaveBuffer False))
    return $ True `elem` results

fileCheckBuffer :: (MonadIDE m) => IDEBuffer -> m Bool
fileCheckBuffer ideBuf@IDEBuffer{sourceView = v} =
    case fileName ideBuf of
        Just _fn -> do
            modifiedOnDisk   <- checkModTime ideBuf -- The user is given option to reload
            modifiedInBuffer <- liftIDE $ getModified =<< getBuffer v
            return (modifiedOnDisk || modifiedInBuffer)
        _ -> return False

fileCheckAll :: MonadIDE m => (IDEBuffer -> m [alpha]) -> m [alpha]
fileCheckAll filterFunc = do
    bufs     <- allBuffers
    fmap concat . forM bufs $ \ buf -> do
        ps <- filterFunc buf
        case ps of
            [] -> return []
            _  -> do
                    modified <- fileCheckBuffer buf
                    if modified
                        then return ps
                        else return []

fileNew :: IDEAction
fileNew = do
    pp      <- getBestPathForId  "*Buffer"
    void $ newTextBuffer pp (__ "Unnamed") Nothing

fileClose :: IDEM Bool
fileClose = inActiveBufContext True fileClose'

fileClose' :: TextEditor editor => EditorView editor -> EditorBuffer editor -> IDEBuffer  -> IDEM Bool
fileClose' _ ebuf currentBuffer = do
    window  <- getMainWindow
    modified <- getModified ebuf
    cancelled <- reifyIDE $ \ideR   ->
        if modified
            then do
                md <- new' MessageDialog [
                        constructDialogUseHeaderBar 0,
                        constructMessageDialogButtons ButtonsTypeCancel]
                setMessageDialogMessageType md MessageTypeQuestion
                setMessageDialogText md $ __ "Save changes to document: "
                                                <> paneName currentBuffer
                                                <> "?"
                windowSetTransientFor md (Just window)
                _ <- dialogAddButton' md (__ "_Save") ResponseTypeYes
                _ <- dialogAddButton' md (__ "_Don't Save") ResponseTypeNo
                dialogSetDefaultResponse' md ResponseTypeYes
                setWindowWindowPosition md WindowPositionCenterOnParent
                resp <- dialogRun' md
                widgetDestroy md
                case resp of
                    ResponseTypeYes -> do
                        _ <- reflectIDE (fileSave False) ideR
                        return False
                    ResponseTypeCancel -> return True
                    ResponseTypeNo     -> return False
                    _                  -> return False
            else return False
    if cancelled
        then return False
        else do
            _ <- closeThisPane currentBuffer
            F.forM_ (fileName currentBuffer) addRecentlyUsedFile
            return True

fileCloseAll :: (IDEBuffer -> IDEM Bool)  -> IDEM Bool
fileCloseAll filterFunc = do
    bufs    <- allBuffers
    filtered <- filterM filterFunc bufs
    case filtered of
        [] -> return True
        (h:_) -> do
            makeActive h
            r <- fileClose
            if r
                then fileCloseAll filterFunc
                else return False

fileCloseAllButPackage :: IDEAction
fileCloseAllButPackage = do
    mbActivePath    <-  fmap ipdPackageDir <$> readIDE activePack
    bufs            <-  allBuffers
    case mbActivePath of
        Just p -> mapM_ (close' p) bufs
        Nothing -> return ()
    where
        close' dir buf@IDEBuffer{sourceView = sv} = do
            ebuf <- getBuffer sv
            when (isJust (fileName buf)) $ do
                modified <- getModified ebuf
                when (not modified && not (isSubPath dir (fromJust (fileName buf))))
                    $ void $ fileClose' sv ebuf buf

fileCloseAllButWorkspace :: IDEAction
fileCloseAllButWorkspace = do
    bufs            <-  allBuffers
    readIDE workspace >>= mapM_ (\ws ->
        unless (null bufs) $ mapM_ (close' ws) bufs)
    where
        close' ws buf@IDEBuffer{sourceView = sv} = do
            ebuf <- getBuffer sv
            when (isJust (fileName buf)) $ do
                modified <- getModified ebuf
                when (not modified && not (isSubPathOfAny ws (fromJust (fileName buf))))
                    $ void $ fileClose' sv ebuf buf
        isSubPathOfAny ws fileName =
            let paths = ipdPackageDir <$> (ws ^. wsPackages)
            in  any (`isSubPath` fileName) paths


fileOpenThis :: FilePath -> IDEAction
fileOpenThis fp =  do
    liftIO . debugM "leksah" $ "fileOpenThis " ++ fp
    fpc <- liftIO $ myCanonicalizePath fp
    findSourceBuf fp >>= \case
        hdb:_ -> do
            window <- getMainWindow
            md <- new' MessageDialog [
                    constructDialogUseHeaderBar 0,
                    constructMessageDialogButtons ButtonsTypeNone]
            setMessageDialogMessageType md MessageTypeQuestion
            setMessageDialogText md $ __ "Buffer already open."
            windowSetTransientFor md (Just window)
            _ <- dialogAddButton' md (__ "Make _Active") (AnotherResponseType 1)
            _ <- dialogAddButton' md (__ "_Open Second") (AnotherResponseType 2)
            dialogSetDefaultResponse' md (AnotherResponseType 1)
            setWindowWindowPosition md WindowPositionCenterOnParent
            resp <- dialogRun' md
            widgetDestroy md
            case resp of
                AnotherResponseType 2 -> reallyOpen fpc
                _                     -> makeActive hdb
        [] -> reallyOpen fpc
    where
        reallyOpen fpc =   do
            pp <-  getBestPathForId "*Buffer"
            void $ newTextBuffer pp (T.pack $ takeFileName fpc) (Just fpc)

filePrint :: IDEAction
filePrint = inActiveBufContext' () filePrint'

filePrint' :: TextEditor editor => Notebook -> EditorView view -> EditorBuffer editor -> IDEBuffer -> Int -> IDEM ()
filePrint' _nb _ ebuf currentBuffer _ = do
    let pName = paneName currentBuffer
    window  <- getMainWindow
    yesPrint <- liftIO $ do
        md <- new' MessageDialog [
                        constructDialogUseHeaderBar 0,
                        constructMessageDialogButtons ButtonsTypeNone]
        setMessageDialogMessageType md MessageTypeQuestion
        setMessageDialogText md $ __"Print document: "
                                                <> pName
                                                <> "?"
        windowSetTransientFor md (Just window)
        _ <- dialogAddButton' md (__"_Print") ResponseTypeYes
        dialogSetDefaultResponse' md ResponseTypeYes
        _ <- dialogAddButton' md (__"_Don't Print") ResponseTypeNo
        setWindowWindowPosition md WindowPositionCenterOnParent
        resp <- dialogRun' md
        widgetDestroy md
        case resp of
            ResponseTypeYes     ->   return True
            ResponseTypeCancel  ->   return False
            ResponseTypeNo      ->   return False
            _                   ->   return False
    when yesPrint $ do
        --real code
        modified <- getModified ebuf
        cancelled <- reifyIDE $ \ideR ->
            if modified
                then do
                    md <- new' MessageDialog [
                        constructDialogUseHeaderBar 0,
                        constructMessageDialogButtons ButtonsTypeNone]
                    setMessageDialogMessageType md MessageTypeQuestion
                    setMessageDialogText md $ __"Save changes to document: "
                                                    <> pName
                                                    <> "?"
                    windowSetTransientFor md (Just window)
                    _ <- dialogAddButton' md (__"_Save") ResponseTypeYes
                    dialogSetDefaultResponse' md ResponseTypeYes
                    _ <- dialogAddButton' md (__"_Don't Save") ResponseTypeNo
                    _ <- dialogAddButton' md (__"_Cancel Printing") ResponseTypeCancel
                    setWindowWindowPosition md WindowPositionCenterOnParent
                    resp <- dialogRun' md
                    widgetDestroy md
                    case resp of
                        ResponseTypeYes ->   do
                            _ <- reflectIDE (fileSave False) ideR
                            return False
                        ResponseTypeCancel  ->   return True
                        ResponseTypeNo      ->   return False
                        _               ->   return False
                else
                    return False
        unless cancelled $
            case fileName currentBuffer of
                Just name -> do
                              status <- liftIO $ Print.print name
                              case status of
                                Left err -> liftIO $ showErrorDialog (Just window) (T.pack $ show err)
                                Right _ -> liftIO $ showDialog (Just window) "Print job has been sent successfully" MessageTypeInfo
                              return ()
                Nothing   -> return ()

editUndo :: IDEAction
editUndo = inActiveBufContext () $ \view buf _ -> do
    can <- canUndo buf
    when can $ do
        undo buf
        scrollToCursor view

editRedo :: IDEAction
editRedo = inActiveBufContext () $ \view buf _ -> do
    can <- canRedo buf
    when can $ redo buf
    scrollToCursor view

editDelete :: IDEAction
editDelete = inActiveBufContext ()  $ \view ebuf _ ->  do
    deleteSelection ebuf
    scrollToCursor view

editSelectAll :: IDEAction
editSelectAll = inActiveBufContext () $ \_ ebuf _ -> do
    start <- getStartIter ebuf
    end   <- getEndIter ebuf
    selectRange ebuf start end

editCut :: IDEAction
editCut = inActiveBufContext () $ \_ ebuf _ -> do
    clip <- clipboardGet =<< atomIntern "CLIPBOARD" False
    cutClipboard ebuf clip True

editCopy :: IDEAction
editCopy = inActiveBufContext () $ \view ebuf _ -> do
    clip <- clipboardGet =<< atomIntern "CLIPBOARD" False
    copyClipboard ebuf clip
    scrollToCursor view

editPaste :: IDEAction
editPaste = inActiveBufContext () $ \_ ebuf _ -> do
    mark <- getInsertMark ebuf
    iter <- getIterAtMark ebuf mark
    clip <- clipboardGet =<< atomIntern "CLIPBOARD" False
    pasteClipboard ebuf clip iter True

editShiftLeft :: IDEAction
editShiftLeft = do
    prefs' <- readIDE prefs
    let str = T.replicate (tabWidth prefs') " "
    b <- canShiftLeft str prefs'
    when b $ do
        _ <- doForSelectedLines [] $ \ebuf lineNr -> do
            sol <- getIterAtLine ebuf lineNr
            sol2 <- forwardCharsC sol (tabWidth prefs')
            delete ebuf sol sol2
        return ()
    where
    canShiftLeft str prefs' = do
        boolList <- doForSelectedLines [] $ \ebuf lineNr -> do
            sol <- getIterAtLine ebuf lineNr
            sol2 <- forwardCharsC sol (tabWidth prefs')
            str1 <- getText ebuf sol sol2 True
            return (str1 == str)
        return (F.foldl' (&&) True boolList)


editShiftRight :: IDEAction
editShiftRight = do
    prefs' <- readIDE prefs
    let str = T.replicate (tabWidth prefs') " "
    _ <- doForSelectedLines [] $ \ebuf lineNr -> do
        sol <- getIterAtLine ebuf lineNr
        insert ebuf sol str
    return ()

align :: Text -> IDEAction
align pat' = inActiveBufContext () $ \_ ebuf ideBuf -> do
    useCandy <- useCandyFor ideBuf
    let pat = if useCandy
                     then transChar pat'
                     else pat'
    (start,end) <- getStartAndEndLineOfSelection ebuf
    beginUserAction ebuf
    let positionsOfChar :: IDEM [(Int, Maybe Int)]
        positionsOfChar = forM [start .. end] $ \lineNr -> do
                sol <- getIterAtLine ebuf lineNr
                eol <- forwardToLineEndC sol
                line  <- getText ebuf sol eol True
                return (lineNr,
                    if pat `T.isInfixOf` line
                        then Just . T.length . fst $ T.breakOn pat line
                        else Nothing)
        alignChar :: Map Int (Maybe Int) -> Int -> IDEM ()
        alignChar positions alignTo =
                forM_ [start .. end] $ \lineNr ->
                    case lineNr `Map.lookup` positions of
                        Just (Just n)  ->  do
                            sol       <- getIterAtLine ebuf lineNr
                            insertLoc <- forwardCharsC sol n
                            insert ebuf insertLoc (T.replicate (alignTo - n) " ")
                        _              ->  return ()
    positions     <- positionsOfChar
    let alignTo = F.foldl' max 0 (mapMaybe snd positions)
    when (alignTo > 0) $ alignChar (Map.fromList positions) alignTo
    endUserAction ebuf

transChar :: Text -> Text
transChar "::" = T.singleton $ toEnum 0x2237 --PROPORTION
transChar "->" = T.singleton $ toEnum 0x2192 --RIGHTWARDS ARROW
transChar "<-" = T.singleton $ toEnum (toEnum 0x2190) --LEFTWARDS ARROW
transChar t    = t

addRecentlyUsedFile :: FilePath -> IDEAction
addRecentlyUsedFile fp = do
    state <- readIDE currentState
    unless (isStartingOrClosing state) $ do
        recentFiles' <- readIDE recentFiles
        unless (fp `elem` recentFiles') $
            modifyIDE_ $ recentFiles .~ take 12 (fp : recentFiles')
        triggerEventIDE_ UpdateRecent

--removeRecentlyUsedFile :: FilePath -> IDEAction
--removeRecentlyUsedFile fp = do
--    state <- readIDE currentState
--    unless (isStartingOrClosing state) $ do
--        recentFiles' <- readIDE recentFiles
--        when (fp `elem` recentFiles') $
--            modifyIDE_ $ recentFiles .~ filter (/= fp) recentFiles'
--        triggerEventIDE_ UpdateRecent

-- | Get the currently selected text or Nothing is no text is selected
selectedText :: IDEM (Maybe IDEBuffer, Maybe Text)
selectedText = do
    candy' <- readIDE candy
    inActiveBufContext (Nothing, Nothing) $ \_ ebuf currentBuffer ->
        hasSelection ebuf >>= \case
            True -> do
                (i1,i2)   <- getSelectionBounds ebuf
                text      <- getCandylessPart candy' ebuf i1 i2
                return (Just currentBuffer, Just text)
            False -> return (Just currentBuffer, Nothing)

-- | Get the currently selected text, or, if none, the current line text
selectedTextOrCurrentLine :: IDEM (Maybe (IDEBuffer, Text))
selectedTextOrCurrentLine = do
    candy' <- readIDE candy
    inActiveBufContext Nothing $ \_ ebuf currentBuffer -> do
        (i1, i2) <- hasSelection ebuf >>= \case
            True -> getSelectionBounds ebuf
            False -> do
                (i, _) <- getSelectionBounds ebuf
                line <- getLine i
                iStart <- getIterAtLine ebuf line
                iEnd <- forwardToLineEndC iStart
                return (iStart, iEnd)
        Just . (currentBuffer,) <$> getCandylessPart candy' ebuf i1 i2

-- | Get the currently selected text, or, if none, tries to selected the current identifier (the one under the cursor)
selectedTextOrCurrentIdentifier :: IDEM (Maybe IDEBuffer, Maybe Text)
selectedTextOrCurrentIdentifier = do
    st <- selectedText
    case snd st of
        Just _ -> return st
        Nothing -> do
            candy' <- readIDE candy
            inActiveBufContext (Nothing, Nothing) $ \_ ebuf currentBuffer -> do
                        (l,r)   <- getIdentifierUnderCursor ebuf
                        t <- getCandylessPart candy' ebuf l r
                        return ( Just currentBuffer
                               , if T.null t
                                        then Nothing
                                        else Just t)

getLocation :: TextEditor e => IDEBuffer -> EditorBuffer e -> EditorIter e -> IDEM (Int, Int)
getLocation buf ebuf iter = do
    candy'     <- readIDE candy
    useCandy   <- useCandyFor buf
    line       <- getLine iter
    lineOffset <- getLineOffset iter
    if useCandy
        then positionFromCandy candy' ebuf (line, lineOffset)
        else return (line, lineOffset)

selectedLocation :: IDEM (Maybe (Int, Int))
selectedLocation =
    inActiveBufContext Nothing $ \_ ebuf currentBuffer -> do
        (start, _) <- getSelectionBounds ebuf
        Just <$> getLocation currentBuffer ebuf start

insertTextAfterSelection :: Text -> IDEAction
insertTextAfterSelection str = do
    candy'       <- readIDE candy
    inActiveBufContext () $ \_ ebuf currentBuffer -> do
        useCandy     <- useCandyFor currentBuffer
        hasSelection ebuf >>= (`when` do
            realString <-  if useCandy then stringToCandy candy' str else return str
            (_,i)      <- getSelectionBounds ebuf
            insert ebuf i realString
            (_,i1)     <- getSelectionBounds ebuf
            i2         <- forwardCharsC i1 (T.length realString)
            selectRange ebuf i1 i2)

-- | Returns the packages to which this buffer belongs
--   uses the 'bufferProjCache' and might extend it
belongsToPackages' :: MonadIDE m => IDEBuffer -> m [(Project, IDEPackage)]
belongsToPackages' = maybe (return []) belongsToPackages . fileName

-- | Checks whether a file belongs to the workspace
belongsToWorkspace' :: MonadIDE m => IDEBuffer -> m Bool
belongsToWorkspace' = maybe (return False) belongsToWorkspace . fileName

useCandyFor :: MonadIDE m => IDEBuffer -> m Bool
useCandyFor aBuffer = do
    prefs' <- readIDE prefs
    return (candyState prefs' && isHaskellMode (mode aBuffer))

switchBuffersCandy :: IDEAction
switchBuffersCandy = do
    prefs' <- readIDE prefs
    buffers <- allBuffers
    forM_ buffers $ \b@IDEBuffer{sourceView=sv} -> do
        buf <- getBuffer sv
        if candyState prefs'
            then modeTransformToCandy (mode b) (modeEditInCommentOrString (mode b)) buf
            else modeTransformFromCandy (mode b) buf

