{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Metainfo.Provider
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- | This module provides the infos collected by the server before
--
---------------------------------------------------------------------------------

module IDE.Metainfo.Provider (
    getIdentifierDescr
,   getIdentifiersStartingWith
,   getCompletionOptions
,   getDescription
,   getActivePackageDescr
,   searchMeta

,   initInfo       -- Update and rebuild
,   updateSystemInfo
,   rebuildSystemInfo
,   updateWorkspaceInfo
,   rebuildWorkspaceInfo

,   getPackageInfo  -- Just retreive from State
,   getWorkspaceInfo
,   getSystemInfo

,   getPackageImportInfo -- Scope for the import tool
,   getAllPackageIds

,   keywords
) where

import Prelude ()
import Prelude.Compat hiding(readFile)
import System.IO (hClose, openBinaryFile, IOMode(..))
import System.IO.Strict (readFile)
import qualified Data.Map as Map
import Control.Monad (void, filterM, foldM, when)
import Control.Lens ((^.), (?~), (.~))
import System.FilePath
import System.Directory
import Data.List (nub, (\\), find, partition, maximumBy, foldl')
import Data.Maybe (catMaybes, fromJust, isJust, mapMaybe, fromMaybe)
import Distribution.Package
import qualified Data.Set as Set
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import Distribution.Version

import Control.DeepSeq
import IDE.Utils.FileUtils
import IDE.Core.Types (IDEEvent(..), IDEState(..), SearchMode(..))
import IDE.Core.CTypes
       (modu, dscMbModu, Descr(..), dscTypeHint, isReexported, dscName,
        dscExported, Present(..), metadataVersion,
        packageIdentifierToString, moduleKeyToName, displayModuleKey,
        ModuleKey(..), SymbolTable(..), Scope(..), Scope, mdIdDescriptions,
        GenScope, SymbolTable, mdMbSourcePath, wcModList, ModuleDescr(..),
        wcProject, wcPackageFile, ModuleKey, wcPackage, pdBuildDepends, wcRebuild, pdModules,
        ServerCommand(..), pdMbSourcePath, ServerAnswer(..), pdPackage,
        PackageDescr(..), TypeDescr(..), dscExported', Descr, dscTypeHint',
        PackScope(..), dscMbComment', GenScope(..), dscMbLocation',
        dscMbModu', dscMbTypeStr', dscName', RealDescr(..),
        SimpleDescr(..), PackageDBs)
import IDE.Core.State
       (sysMessage, throwIDE, ipdCabalFile, ipdDepends,
        ipdMain, ipdModules, ipdPackageId, activePack, modifyIDE_,
        wsAllPackages, workspace, currentState,
        triggerEventIDE, forkIDE, MessageLevel(..),
        ideMessage, collectAtStart, prefs, readIDE,
        ModuleDescrCache, workspInfoCache, IDEPackage, packageInfo,
        workspaceInfo, systemInfo, IDEM, IDEAction, wsProjectFiles,
        Project, pjFile, wsProjectAndPackages, systemInfo)
import IDE.Gtk.State (postAsyncIDE)
import IDE.Utils.Utils
       (leksahMetadataPathFileExtension,
        leksahMetadataSystemFileExtension,
        leksahMetadataWorkspaceFileExtension)
import Data.Char (toLower,isUpper,toUpper,isLower)
import Text.Regex.TDFA
import qualified Text.Regex.TDFA as Regex
import System.IO.Unsafe (unsafePerformIO)
import Text.Regex.TDFA.Text (execute,compile)
import Data.Binary.Shared (decodeSer)
import Language.Haskell.Extension (KnownExtension)
import Distribution.Text (display)
import IDE.Core.Serializable ()
import Data.Map (Map)
import Control.Exception (SomeException(..), catch)
import IDE.Utils.ServerConnection(doServerCommand)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Distribution.PackageDescription (hsSourceDirs)
import System.Log.Logger (debugM, infoM)
import Data.Text (Text)
import qualified Data.Text as T (null, isPrefixOf, unpack, pack)
import qualified Control.Arrow as A (Arrow(..))
import Data.Function (on)
import IDE.Utils.CabalPlan (unitIdToPackageId)

-- ---------------------------------------------------------------------
-- Updating metadata
--

--
-- | Update and initialize metadata for the world -- Called at startup
--
initInfo :: IDEAction -> IDEAction
initInfo continuation = do
    prefs'  <- readIDE prefs
    if collectAtStart prefs'
        then do
            ideMessage Normal "Now updating system metadata ..."
            callCollector False True True $ \ _ -> do
                ideMessage Normal "Finished updating system metadata"
                doLoad
        else doLoad
    where
      doLoad = do
            ideMessage Normal "Now loading metadata ..."
            forkIDE $ do
                loadSystemInfo
                postAsyncIDE $ do
                    ideMessage Normal "Finished loading metadata"
                    updateWorkspaceInfo' False $ \ _ -> do
                        void (triggerEventIDE (InfoChanged True))
                        continuation

updateSystemInfo :: IDEAction
updateSystemInfo     = do
    liftIO $ infoM "leksah" "update sys info called"
    currentState' <- readIDE currentState
    case currentState' of
        IsStartingUp -> return ()
        _ ->
            updateSystemInfo' False $ \ _ ->
                updateWorkspaceInfo' False $ \ _ -> void (triggerEventIDE (InfoChanged False))

rebuildSystemInfo :: IDEAction
rebuildSystemInfo    = do
    liftIO $ infoM "leksah" "rebuild sys info called"
    updateSystemInfo' True $ \ _ ->
        updateWorkspaceInfo' True $ \ _ ->
            void (triggerEventIDE (InfoChanged False))

updateWorkspaceInfo :: IDEAction
updateWorkspaceInfo = do
    liftIO $ infoM "leksah" "update workspace info called"
    currentState' <- readIDE currentState
    case currentState' of
        IsStartingUp -> return ()
        _ ->
            updateWorkspaceInfo' False $ \ _ ->
                void (triggerEventIDE (InfoChanged False))

rebuildWorkspaceInfo :: IDEAction
rebuildWorkspaceInfo = do
    liftIO $ infoM "leksah" "rebuild workspace info called"
    updateWorkspaceInfo' True $ \ _ ->
        void (triggerEventIDE (InfoChanged False))

getAllPackages :: IDEM [(UnitId, Maybe FilePath)]
getAllPackages = do
    mbWorkspace <- readIDE workspace
    liftIO $ getInstalledPackages VERSION_ghc
            $ maybe [] (^. wsProjectFiles) mbWorkspace

getAllPackageIds :: IDEM [PackageIdentifier]
getAllPackageIds =
    nub . mapMaybe (unitIdToPackageId . fst) <$>
        getAllPackages

getAllPackageDBs :: IDEM [PackageDBs]
getAllPackageDBs = do
    mbWorkspace <- readIDE workspace
    liftIO . getPackageDBs $ maybe [] (^. wsProjectFiles) mbWorkspace

--
-- | Load all infos for all installed and exposed packages
--   (see shell command: ghc-pkg list)
--
loadSystemInfo :: IDEAction
loadSystemInfo = do
    liftIO $ debugM "leksah" "loadSystemInfo"
    collectorPath   <-  liftIO getCollectorPath
    packageIds      <-  getAllPackageIds
    packageList     <-  liftIO $ mapM (loadInfosForPackage collectorPath) packageIds
    let scope       =   foldr buildScope (PackScope Map.empty getEmptyDefaultScope)
                            $ catMaybes packageList
--    liftIO performGC
    modifyIDE_ $ systemInfo ?~ GenScopeC (addOtherToScope scope False)

    return ()

--
-- | Updates the system info
--
updateSystemInfo' :: Bool -> (Bool -> IDEAction) -> IDEAction
updateSystemInfo' rebuild continuation = do
    ideMessage Normal "Now updating system metadata ..."
    wi              <-  getSystemInfo
    case wi of
        Nothing -> loadSystemInfo
        Just (GenScopeC (PackScope psmap _psst)) -> forkIDE $ do
            liftIO $ debugM "leksah" "A"
            packageIds      <-  getAllPackageIds
            liftIO . debugM "leksah" $ "packageIds = " <> show packageIds
            let newPackages     =   filter (`Map.notMember` psmap) packageIds
            let trashPackages   =   filter (`notElem` packageIds) (Map.keys psmap)
            liftIO . debugM "leksah" $ "newPackages = " <> show newPackages
            liftIO . debugM "leksah" $ "trashPackages = " <> show trashPackages
            if null newPackages && null trashPackages
                then finished
                else
                    callCollector rebuild True True $ \ _ -> do
                        collectorPath   <-  lift getCollectorPath
                        newPackageInfos <-  liftIO $ mapM (loadInfosForPackage collectorPath)
                                                            (nub newPackages)
                        let psmap2      =   foldr (\ e m -> Map.insert (pdPackage e) e m) psmap
                                               (catMaybes newPackageInfos)
                        let psmap3      =   foldr Map.delete psmap2 trashPackages
                        let scope :: PackScope (Map Text [Descr])
                                        =   foldr buildScope (PackScope Map.empty symEmpty)
                                                (Map.elems psmap3)
                        postAsyncIDE $ do
                            modifyIDE_ $ systemInfo ?~ GenScopeC (addOtherToScope scope False)
                            finished
  where
    finished = do
        postAsyncIDE $ ideMessage Normal "Finished updating system metadata"
        continuation True

getEmptyDefaultScope :: Map Text [Descr]
getEmptyDefaultScope = symEmpty

--
-- | Rebuilds system info
--
--rebuildSystemInfo' :: (Bool -> IDEAction) -> IDEAction
--rebuildSystemInfo' continuation =
--    callCollector True True True $ \ _ -> do
--        loadSystemInfo
--        continuation True

-- ---------------------------------------------------------------------
-- Metadata for the workspace and active package
--

updateWorkspaceInfo' :: Bool -> (Bool -> IDEAction) -> IDEAction
updateWorkspaceInfo' rebuild continuation = do
    postAsyncIDE $ ideMessage Normal "Now updating workspace metadata ..."
    mbWorkspace         <- readIDE workspace
    systemInfo'         <- getSystemInfo
    case mbWorkspace of
        Nothing ->  do
            liftIO $ infoM "leksah" "updateWorkspaceInfo' no workspace"
            modifyIDE_ $ (workspaceInfo .~ Nothing)
                       . (packageInfo   .~ Nothing)
            continuation False
        Just ws ->
            updatePackageInfos rebuild (ws ^. wsProjectAndPackages) $ \ _ packDescrs -> do
                let dependPackIds = nub (concatMap pdBuildDepends packDescrs) \\ map pdPackage packDescrs
                let packDescrsI =   case systemInfo' of
                                        Nothing -> []
                                        Just (GenScopeC (PackScope pdmap _)) ->
                                            mapMaybe (`Map.lookup` pdmap) dependPackIds
                let scope1 :: PackScope (Map Text [Descr])
                                =   foldr buildScope (PackScope Map.empty symEmpty) packDescrs
                let scope2 :: PackScope (Map Text [Descr])
                                =   foldr buildScope (PackScope Map.empty symEmpty) packDescrsI
                modifyIDE_ $ workspaceInfo ?~
                    (GenScopeC (addOtherToScope scope1 True), GenScopeC(addOtherToScope scope2 False))
                -- Now care about active package
                readIDE activePack >>= \case
                    Nothing -> modifyIDE_ $ packageInfo .~ Nothing
                    Just pack ->
                        case filter (\pd -> pdPackage pd == ipdPackageId pack) packDescrs of
                            [pd] -> let impPackDescrs =
                                            case systemInfo' of
                                                Nothing -> []
                                                Just (GenScopeC (PackScope pdmap _)) ->
                                                     mapMaybe (`Map.lookup` pdmap) (pdBuildDepends pd)
                                        -- The imported from the workspace should be treated different
                                        workspacePackageIds = map ipdPackageId (ws ^. wsAllPackages)
                                        impPackDescrs' = filter (\ipd -> pdPackage ipd `notElem` workspacePackageIds) impPackDescrs
                                        impPackDescrs'' = mapMaybe
                                                             (\ ipd -> if pdPackage ipd `elem` workspacePackageIds
                                                                        then find (\ pd' -> pdPackage ipd == pdPackage pd') packDescrs
                                                                        else Nothing)
                                                             impPackDescrs
                                        scope1' :: PackScope (Map Text [Descr])
                                                =   buildScope pd (PackScope Map.empty symEmpty)
                                        scope2' :: PackScope (Map Text [Descr])
                                                =   foldr buildScope (PackScope Map.empty symEmpty)
                                                        (impPackDescrs' ++ impPackDescrs'')
                                        in modifyIDE_ $ packageInfo ?~
                                                            (GenScopeC (addOtherToScope scope1' False),
                                                            GenScopeC(addOtherToScope scope2' False))
                            _    -> modifyIDE_ $ packageInfo .~ Nothing
                postAsyncIDE $ ideMessage Normal "Finished updating workspace metadata"
                continuation True

-- | Update the metadata on several packages
updatePackageInfos :: Bool -> [(Project, IDEPackage)] -> (Bool -> [PackageDescr] -> IDEAction) -> IDEAction
updatePackageInfos rebuild pkgs continuation =
    forkIDE $ do
        -- calculate list of known packages once
        knownPackages   <- getAllPackageIds
        postAsyncIDE $
            updatePackageInfos' [] knownPackages pkgs
  where
    updatePackageInfos' collector _ [] =  continuation True collector
    updatePackageInfos' collector knownPackages ((project, package):rest) =
        updatePackageInfo knownPackages rebuild project package $ \ _ packDescr ->
            updatePackageInfos' (packDescr : collector) knownPackages rest

-- | Update the metadata on one package
updatePackageInfo :: [PackageIdentifier] -> Bool -> Project -> IDEPackage -> (Bool -> PackageDescr -> IDEAction) -> IDEAction
updatePackageInfo knownPackages rebuild project idePack continuation = do
    liftIO $ infoM "leksah" ("updatePackageInfo " ++ show rebuild ++ " " ++ show (ipdPackageId idePack))
    workspInfoCache'     <- readIDE workspInfoCache
    let packageMap = fromMaybe mempty $ pid `Map.lookup` workspInfoCache'
    modPairsMb <- liftIO $ mapM (\(modName, bi) -> do
            sf <- case  LibModule modName `Map.lookup` packageMap of
                        Nothing            -> findSourceFile (srcDirs' bi) haskellSrcExts modName
                        Just (_,Nothing,_) -> findSourceFile (srcDirs' bi) haskellSrcExts modName
                        Just (_,Just fp,_) -> return (Just fp)
            return (LibModule modName, sf))
                $ Map.toList $ ipdModules idePack
    mainModules <- liftIO $ mapM (\(fn, bi, _isTest) -> do
                                    mbFn <- findSourceFile' (srcDirs' bi) fn
                                    return (MainModule (fromMaybe fn mbFn), mbFn))
                            (ipdMain idePack)
    -- we want all Main modules since they may be several with different files
    let modPairsMb' = mainModules ++ modPairsMb
    let (modWith,modWithout) = partition (\(_x,y) -> isJust y) modPairsMb'
    let modWithSources       = map (A.second fromJust) modWith
    let modWithoutSources    = map fst modWithout
    -- Now see which modules have to be truely updated
    modToUpdate <- if rebuild
                            then return modWithSources
                            else liftIO $ figureOutRealSources idePack modWithSources
    liftIO . infoM "leksah" $ "updatePackageInfo modToUpdate " ++ show (map (displayModuleKey.fst) modToUpdate)
    callCollectorWorkspace
        rebuild
        project
        idePack
        (map (\(x,y) -> (T.pack $ display (moduleKeyToName x),y)) modToUpdate)
        (\_ -> do
            let buildDepends         = findFittingPackages knownPackages (ipdDepends idePack)
            liftIO . putStrLn $ "buildDepends = " <> show buildDepends
            collectorPath        <- liftIO getCollectorPath
            let packageCollectorPath = collectorPath </> T.unpack (packageIdentifierToString pid)
            (moduleDescrs,packageMap', changed, _modWithout)
                                 <- liftIO $ foldM
                                        (getModuleDescr packageCollectorPath)
                                        ([],packageMap,False,modWithoutSources)
                                        modPairsMb'
            when changed $ modifyIDE_ $ workspInfoCache .~
                                            Map.insert pid packageMap' workspInfoCache'
            continuation True PackageDescr {
                pdPackage        = pid,
                pdMbSourcePath   = Just $ ipdCabalFile idePack,
                pdModules        = moduleDescrs,
                pdBuildDepends   = buildDepends})
    where
        basePath =  normalise $ takeDirectory (ipdCabalFile idePack)
        srcDirs' bi =  map (basePath </>) ("dist/build":hsSourceDirs bi)
        pid = ipdPackageId idePack

figureOutRealSources :: IDEPackage -> [(ModuleKey,FilePath)] -> IO [(ModuleKey,FilePath)]
figureOutRealSources idePack modWithSources = do
    collectorPath <- getCollectorPath
    let packageCollectorPath = collectorPath </> T.unpack (packageIdentifierToString $ ipdPackageId idePack)
    filterM (ff packageCollectorPath) modWithSources
    where
        ff packageCollectorPath (md ,fp) =  do
            let collectorModulePath = packageCollectorPath </> moduleCollectorFileName md <.> leksahMetadataWorkspaceFileExtension
            existCollectorFile <- doesFileExist collectorModulePath
            existSourceFile    <- doesFileExist fp
            if not existSourceFile || not existCollectorFile
                then return True -- Maybe with preprocessing
                else do
                    sourceModTime <-  getModificationTime fp
                    collModTime   <-  getModificationTime collectorModulePath
                    return (sourceModTime > collModTime)


getModuleDescr :: FilePath
    -> ([ModuleDescr],ModuleDescrCache,Bool,[ModuleKey])
    -> (ModuleKey, Maybe FilePath)
    -> IO ([ModuleDescr],ModuleDescrCache,Bool,[ModuleKey])
getModuleDescr packageCollectorPath (modDescrs,packageMap,changed,problemMods) (modName,mbFilePath) =
    case modName `Map.lookup` packageMap of
        Just (eTime,_mbFp,mdescr) -> do
            existMetadataFile <- doesFileExist moduleCollectorPath
            if existMetadataFile
                then do
                    modificationTime <- liftIO $ getModificationTime moduleCollectorPath
                    if modificationTime == eTime
                        then return (mdescr:modDescrs,packageMap,changed,problemMods)
                        else do
                            liftIO . infoM "leksah" $ "getModuleDescr loadInfo: " ++ displayModuleKey modName
                            mbNewDescr <- loadInfosForModule moduleCollectorPath
                            case mbNewDescr of
                                Just newDescr -> return (newDescr:modDescrs,
                                                    Map.insert modName (modificationTime,mbFilePath,newDescr) packageMap,
                                                    True, problemMods)
                                Nothing       -> return (mdescr:modDescrs,packageMap,changed,
                                                    modName : problemMods)
                else return (mdescr:modDescrs,packageMap,changed, modName : problemMods)
        Nothing -> do
            existMetadataFile <- doesFileExist moduleCollectorPath
            if existMetadataFile
                then do
                    modificationTime <- liftIO $ getModificationTime moduleCollectorPath
                    mbNewDescr       <- loadInfosForModule moduleCollectorPath
                    case mbNewDescr of
                        Just newDescr -> return (newDescr:modDescrs,
                                    Map.insert modName (modificationTime,mbFilePath,newDescr) packageMap,
                                        True, problemMods)
                        Nothing       -> return (modDescrs,packageMap,changed,
                                        modName : problemMods)
                else return (modDescrs,packageMap,changed, modName : problemMods)
    where
        moduleCollectorPath = packageCollectorPath </> moduleCollectorFileName modName <.>  leksahMetadataWorkspaceFileExtension

-- ---------------------------------------------------------------------
-- Low level helpers for loading metadata
--

--
-- | Loads the infos for the given packages
--
loadInfosForPackage :: FilePath -> PackageIdentifier -> IO (Maybe PackageDescr)
loadInfosForPackage dirPath pid = do
    let filePath = dirPath </> T.unpack (packageIdentifierToString pid) ++ leksahMetadataSystemFileExtension
    let filePath2 = dirPath </> T.unpack (packageIdentifierToString pid) ++ leksahMetadataPathFileExtension
    exists <- doesFileExist filePath
    if exists
        then catch (do
            file            <-  openBinaryFile filePath ReadMode
            liftIO . infoM "leksah" . T.unpack $ "now loading metadata for package " <> packageIdentifierToString pid
            bs              <-  BSL.hGetContents file
            let (metadataVersion'::Integer, packageInfo'::PackageDescr) = decodeSer bs
            if metadataVersion /= metadataVersion'
                then do
                    hClose file
                    throwIDE ("Metadata has a wrong version."
                            <>  " Consider rebuilding metadata with: leksah-server -osb +RTS -N2 -RTS")
                else do
                    packageInfo' `deepseq` hClose file
                    exists'  <-  doesFileExist filePath2
                    sourcePath <- if exists'
                                    then Just <$> readFile filePath2
                                    else return Nothing
                    let packageInfo'' = injectSourceInPack sourcePath packageInfo'
                    return (Just packageInfo''))
            (\ (e :: SomeException) -> do
                sysMessage Normal
                    ("loadInfosForPackage: " <> packageIdentifierToString pid <> " Exception: " <> T.pack (show e))
                return Nothing)
        else do
            sysMessage Normal $"packageInfo not found for " <> packageIdentifierToString pid
            return Nothing

injectSourceInPack :: Maybe FilePath -> PackageDescr -> PackageDescr
injectSourceInPack Nothing pd = pd{
    pdMbSourcePath = Nothing,
    pdModules      = map (injectSourceInMod Nothing) (pdModules pd)}
injectSourceInPack (Just pp) pd = pd{
    pdMbSourcePath = Just pp,
    pdModules      = map (injectSourceInMod (Just (dropFileName pp))) (pdModules pd)}

injectSourceInMod :: Maybe FilePath -> ModuleDescr -> ModuleDescr
injectSourceInMod Nothing md = md{mdMbSourcePath = Nothing}
injectSourceInMod (Just bp) md =
    case mdMbSourcePath md of
        Just sp -> md{mdMbSourcePath = Just (bp </> sp)}
        Nothing -> md

--
-- | Loads the infos for the given module
--
loadInfosForModule :: FilePath -> IO (Maybe ModuleDescr)
loadInfosForModule filePath  = do
    exists <- doesFileExist filePath
    if exists
        then catch (do
            file            <-  openBinaryFile filePath ReadMode
            bs              <-  BSL.hGetContents file
            let (metadataVersion'::Integer, moduleInfo::ModuleDescr) = decodeSer bs
            if metadataVersion /= metadataVersion'
                then do
                    hClose file
                    throwIDE ("Metadata has a wrong version."
                           <> " Consider rebuilding metadata with -r option")
                else do
                    moduleInfo `deepseq` hClose file
                    return (Just moduleInfo))
            (\ (e :: SomeException) -> do sysMessage Normal (T.pack $ "loadInfosForModule: " ++ show e); return Nothing)
        else do
            sysMessage Normal $ "moduleInfo not found for " <> T.pack filePath
            return Nothing

-- | Find the packages fitting the dependencies
findFittingPackages
    :: [PackageIdentifier] -- ^ the list of known packages
    -> [Dependency]  -- ^ the dependencies
    -> [PackageIdentifier] -- ^ the known packages matching the dependencies
findFittingPackages knownPackages =
    concatMap (fittingKnown knownPackages) . concatMap addReexportDeps
    where
    fittingKnown packages (Dependency dname versionRange) =
        -- find matching packages
        let filtered =  filter (\ (PackageIdentifier name version) ->
                                    name == dname && withinRange version versionRange)
                        packages
        -- take latest version if several versions match
        in  if length filtered > 1
                then [maximumBy (compare `on` pkgVersion) filtered]
                else filtered

-- Some packages rexport modules and we don't handle that correctly yet.
-- For now we should just consider these packages as "fitting".
addReexportDeps :: Dependency -> [Dependency]
addReexportDeps d@(Dependency dname _versionRange)
    | dname == mkPackageName "ghcjs-dom"  = [d, Dependency (mkPackageName "jsaddle-dom")     anyVersion]
    | dname == mkPackageName "reflex-dom" = [d, Dependency (mkPackageName "reflex-dom-core") anyVersion]
addReexportDeps d = [d]

-- ---------------------------------------------------------------------
-- Looking up and searching metadata
--

getActivePackageDescr :: IDEM (Maybe PackageDescr)
getActivePackageDescr = do
    mbActive <- readIDE activePack
    case mbActive of
        Nothing -> return Nothing
        Just pack -> do
            packageInfo' <- getPackageInfo
            case packageInfo' of
                Nothing -> return Nothing
                Just (GenScopeC (PackScope map' _), GenScopeC (PackScope _ _)) ->
                    return (ipdPackageId pack `Map.lookup` map')

--
-- | Lookup of an identifier description
--
getIdentifierDescr :: (SymbolTable alpha, SymbolTable beta)  => Text -> alpha   -> beta   -> [Descr]
getIdentifierDescr str st1 st2 =
    let r1 = str `symLookup` st1
        r2 = str `symLookup` st2
    in r1 ++ r2

--
-- | Lookup of an identifiers starting with the specified prefix and return a list.
--
getIdentifiersStartingWith :: (SymbolTable alpha , SymbolTable beta)  => Text -> alpha   -> beta   -> [Text]
getIdentifiersStartingWith prefix st1 st2 =
    takeWhile (T.isPrefixOf prefix) $
        if memberLocal || memberGlobal then
            prefix : Set.toAscList names
            else
            Set.toAscList names
    where
        (_, memberLocal, localNames) = Set.splitMember prefix (symbols st1)
        (_, memberGlobal, globalNames) = Set.splitMember prefix (symbols st2)
        names = Set.union globalNames localNames

getCompletionOptions :: Text -> IDEM [Text]
getCompletionOptions prefix = do
    workspaceInfo' <- getWorkspaceInfo
    case workspaceInfo' of
        Nothing -> return []
        Just (GenScopeC (PackScope _ symbolTable1), GenScopeC (PackScope _ symbolTable2)) ->
            return $ getIdentifiersStartingWith prefix symbolTable1 symbolTable2

getDescription :: Text -> IDEM Text
getDescription name = do
    workspaceInfo' <- getWorkspaceInfo
    case workspaceInfo' of
        Nothing -> return ""
        Just (GenScopeC (PackScope _ symbolTable1), GenScopeC (PackScope _ symbolTable2)) ->
            return $ T.pack (foldr (\d f -> shows (Present d) .  showChar '\n' . f) id
                (getIdentifierDescr name symbolTable1 symbolTable2) "")

getPackageInfo :: IDEM (Maybe (GenScope, GenScope))
getPackageInfo   =  readIDE packageInfo

getWorkspaceInfo :: IDEM (Maybe (GenScope, GenScope))
getWorkspaceInfo =  readIDE workspaceInfo

getSystemInfo :: IDEM (Maybe GenScope)
getSystemInfo    =  readIDE systemInfo

-- | Only exported items
getPackageImportInfo :: IDEPackage -> IDEM (Maybe (GenScope,GenScope))
getPackageImportInfo idePack = do
    mbActivePack  <- readIDE activePack
    systemInfo'   <- getSystemInfo
    if isJust mbActivePack && ipdPackageId (fromJust mbActivePack) == ipdPackageId idePack
        then
            getPackageInfo >>= \case
                Nothing -> do
                    liftIO $ infoM "leksah" "getPackageImportInfo: no package info"
                    return Nothing
                Just (GenScopeC (PackScope pdmap _), _) ->
                     case Map.lookup (ipdPackageId idePack) pdmap of
                        Nothing -> do
                            liftIO $ infoM "leksah" "getPackageImportInfo: package not found in package"
                            return Nothing
                        Just pd -> buildIt pd systemInfo'
        else
            getWorkspaceInfo >>= \case
                Nothing -> do
                    liftIO $ infoM "leksah" "getPackageImportInfo: no workspace info"
                    return Nothing
                Just (GenScopeC (PackScope pdmap _), _) ->
                    case Map.lookup (ipdPackageId idePack) pdmap of
                        Nothing -> do
                            liftIO $ infoM "leksah" "getPackageImportInfo: package not found in workspace"
                            return Nothing
                        Just pd -> buildIt pd systemInfo'

    where
        filterPrivate :: ModuleDescr -> ModuleDescr
        filterPrivate md = md{mdIdDescriptions = filter dscExported (mdIdDescriptions md)}
        buildIt pd systemInfo' =
                case systemInfo' of
                    Nothing -> do
                        liftIO $ infoM "leksah" "getPackageImportInfo: no system info"
                        return Nothing
                    Just (GenScopeC (PackScope pdmap' _)) ->
                        let impPackDescrs = mapMaybe (`Map.lookup` pdmap') (pdBuildDepends pd)
                            pd' = pd{pdModules = map filterPrivate (pdModules pd)}
                            scope1 :: PackScope (Map Text [Descr])
                                            =   buildScope pd' (PackScope Map.empty symEmpty)
                            scope2 :: PackScope (Map Text [Descr])
                                =   foldr buildScope (PackScope Map.empty symEmpty) impPackDescrs
                        in return (Just (GenScopeC scope1, GenScopeC scope2))
--
-- | Searching of metadata
--

searchMeta :: Scope -> Text -> SearchMode -> IDEM [Descr]
searchMeta _ "" _ = return []
searchMeta (PackageScope False) searchString searchType = do
    packageInfo'    <- getPackageInfo
    case packageInfo' of
        Nothing    -> return []
        Just (GenScopeC (PackScope _ rl), _) -> return (searchInScope searchType searchString rl)
searchMeta (PackageScope True) searchString searchType = do
    packageInfo'    <- getPackageInfo
    case packageInfo' of
        Nothing    -> return []
        Just (GenScopeC (PackScope _ rl), GenScopeC (PackScope _ rr)) ->
            return (searchInScope searchType searchString rl
                                ++  searchInScope searchType searchString rr)
searchMeta (WorkspaceScope False) searchString searchType = do
    workspaceInfo'    <- getWorkspaceInfo
    case workspaceInfo' of
        Nothing    -> return []
        Just (GenScopeC (PackScope _ rl), _) -> return (searchInScope searchType searchString rl)
searchMeta (WorkspaceScope True) searchString searchType = do
    workspaceInfo'    <- getWorkspaceInfo
    case workspaceInfo' of
        Nothing    -> return []
        Just (GenScopeC (PackScope _ rl), GenScopeC (PackScope _ rr)) ->
            return (searchInScope searchType searchString rl
                                ++  searchInScope searchType searchString rr)
searchMeta SystemScope searchString searchType = do
    systemInfo'  <- getSystemInfo
    packageInfo' <- getPackageInfo
    case systemInfo' of
        Nothing ->
            case packageInfo' of
                        Nothing    -> return []
                        Just (GenScopeC (PackScope _ rl), _) ->
                                return (searchInScope searchType searchString rl)
        Just (GenScopeC (PackScope _ s)) ->
            case packageInfo' of
                Nothing    -> return (searchInScope searchType searchString s)
                Just (GenScopeC (PackScope _ rl), _) -> return (searchInScope searchType searchString rl
                                        ++  searchInScope searchType searchString s)

searchInScope :: SymbolTable alpha =>  SearchMode -> Text -> alpha  -> [Descr]
searchInScope (Exact _)  l st      = searchInScopeExact l st
searchInScope (Prefix True) l st   = (concat . symElems) (searchInScopePrefix l st)
searchInScope (Prefix False) l _ | T.null l = []
searchInScope (Prefix False) l st  = (concat . symElems) (searchInScopeCaseIns l st "")
searchInScope (Regex b) l st       = searchRegex l st b


searchInScopeExact :: SymbolTable alpha =>  Text -> alpha  -> [Descr]
searchInScopeExact = symLookup

searchInScopePrefix :: SymbolTable alpha   =>  Text -> alpha  -> alpha
searchInScopePrefix searchString symbolTable =
    let (_, exact, mapR)   = symSplitLookup searchString symbolTable
        (mbL, _, _)        = symSplitLookup (searchString <> "{") mapR
    in case exact of
            Nothing -> mbL
            Just e  -> symInsert searchString e mbL

searchInScopeCaseIns :: SymbolTable alpha => Text -> alpha -> Text -> alpha
searchInScopeCaseIns a' symbolTable b  = searchInScopeCaseIns' (T.unpack a') symbolTable (T.unpack b)
  where
  searchInScopeCaseIns' [] st _                    =  st
  searchInScopeCaseIns' (a:l)  st pre | isLower a  =
    let s1 = pre ++ [a]
        s2 = pre ++ [toUpper a]
    in  symUnion (searchInScopeCaseIns' l (searchInScopePrefix (T.pack s1) st) s1)
                 (searchInScopeCaseIns' l (searchInScopePrefix (T.pack s2) st) s2)
                                   | isUpper a  =
    let s1 = pre ++ [a]
        s2 = pre ++ [toLower a]
    in  symUnion (searchInScopeCaseIns' l (searchInScopePrefix (T.pack s1) st) s1)
                 (searchInScopeCaseIns' l (searchInScopePrefix (T.pack s2) st) s2)
                                    | otherwise =
    let s =  pre ++ [a]
    in searchInScopeCaseIns' l (searchInScopePrefix (T.pack s) st) s


searchRegex :: SymbolTable alpha => Text -> alpha  -> Bool -> [Descr]
searchRegex searchString st caseSense =
    case compileRegex caseSense searchString of
        Left err ->
            unsafePerformIO $ sysMessage Normal (T.pack $ show err) >> return []
        Right regex ->
            filter (\e ->
                case execute regex (dscName e) of
                    Left _e       -> False
                    Right Nothing -> False
                    _             -> True)
                        (concat (symElems st))

compileRegex :: Bool -> Text -> Either String Regex
compileRegex caseSense searchString =
    let compOption = defaultCompOpt {
                            Regex.caseSensitive = caseSense
                        ,   multiline = True } in
    compile compOption defaultExecOpt searchString

-- ---------------------------------------------------------------------
-- Handling of scopes
--

--
-- | Loads the infos for the given packages (has an collecting argument)
--
buildScope :: SymbolTable alpha  =>  PackageDescr -> PackScope alpha  -> PackScope alpha
buildScope packageD (PackScope packageMap symbolTable) =
    let pid = pdPackage packageD
    in if pid `Map.member` packageMap
        then PackScope packageMap symbolTable
        else PackScope (Map.insert pid packageD packageMap)
                  (buildSymbolTable packageD symbolTable)

buildSymbolTable :: SymbolTable alpha  =>  PackageDescr -> alpha  -> alpha
buildSymbolTable pDescr symbolTable =
     foldl' buildScope'
            symbolTable allDescriptions
    where
        allDescriptions =  concatMap mdIdDescriptions (pdModules pDescr)
        buildScope' st idDescr =
            let allDescrs = allDescrsFrom idDescr
            in  foldl' (\ map' descr -> symInsert (dscName descr) [descr] map')
                        st allDescrs
        allDescrsFrom descr | isReexported descr = [descr]
                            | otherwise =
            case dscTypeHint descr of
                DataDescr constructors fields ->
                    descr : map (\(SimpleDescr fn ty loc comm exp') ->
                        Real RealDescr{dscName' = fn, dscMbTypeStr' = ty,
                            dscMbModu' = dscMbModu descr, dscMbLocation' = loc,
                            dscMbComment' = comm, dscTypeHint' = FieldDescr descr, dscExported' = exp'})
                            fields
                            ++  map (\(SimpleDescr fn ty loc comm exp') ->
                        Real RealDescr{dscName' = fn, dscMbTypeStr' = ty,
                            dscMbModu' = dscMbModu descr, dscMbLocation' = loc,
                            dscMbComment' = comm, dscTypeHint' = ConstructorDescr descr, dscExported' = exp'})
                                constructors
                ClassDescr _ methods ->
                    descr : map (\(SimpleDescr fn ty loc comm exp') ->
                        Real RealDescr{dscName' = fn, dscMbTypeStr' = ty,
                            dscMbModu' = dscMbModu descr, dscMbLocation' = loc,
                            dscMbComment' = comm, dscTypeHint' = MethodDescr descr, dscExported' = exp'})
                            methods
                NewtypeDescr (SimpleDescr fn ty loc comm exp') mbField ->
                    descr : Real RealDescr{dscName' = fn, dscMbTypeStr' = ty,
                            dscMbModu' = dscMbModu descr, dscMbLocation' = loc,
                            dscMbComment' = comm, dscTypeHint' = ConstructorDescr descr, dscExported' = exp'}
                             : case mbField of
                                    Just (SimpleDescr fn' ty' loc' comm' exp'') ->
                                        [Real RealDescr{dscName' = fn', dscMbTypeStr' = ty',
                                        dscMbModu' = dscMbModu descr, dscMbLocation' = loc',
                                        dscMbComment' = comm', dscTypeHint' = FieldDescr descr, dscExported' = exp''}]
                                    Nothing -> []
                InstanceDescr _ -> []
                _ -> [descr]


-- ---------------------------------------------------------------------
-- Low level functions for calling the collector
--

callCollector :: Bool -> Bool -> Bool -> (Bool -> IDEAction) -> IDEAction
callCollector scRebuild scSources scExtract cont = do
    liftIO $ infoM "leksah" "callCollector"
    scPackageDBs <- getAllPackageDBs
    doServerCommand SystemCommand {..} $ \case
        ServerOK         -> do
            liftIO $ infoM "leksah" "callCollector finished"
            cont True
        ServerFailed str -> do
            liftIO $ infoM "leksah" (T.unpack str)
            cont False
        _                -> do
            liftIO $ infoM "leksah" "impossible server answer"
            cont False

callCollectorWorkspace :: Bool -> Project -> IDEPackage -> [(Text,FilePath)] ->
    (Bool -> IDEAction) -> IDEAction
callCollectorWorkspace rebuild project package modList cont = do
    liftIO $ infoM "leksah" "callCollectorWorkspace"
    if null modList
        then do
            liftIO $ infoM "leksah" "callCollectorWorkspace: Nothing to do"
            cont True
        else
            doServerCommand command  $ \case
                ServerOK         -> do
                    liftIO $ infoM "leksah" "callCollectorWorkspace finished"
                    cont True
                ServerFailed str -> do
                    liftIO $ infoM "leksah" (T.unpack str)
                    cont False
                _                -> do
                    liftIO $ infoM "leksah" "impossible server answer"
                    cont False
    where command = WorkspaceCommand {
            wcRebuild     = rebuild,
            wcPackage     = ipdPackageId package,
            wcProject     = pjFile project,
            wcPackageFile = ipdCabalFile package,
            wcModList     = modList}

-- ---------------------------------------------------------------------
-- Additions for completion
--

keywords :: [Text]
keywords = [
        "as"
    ,   "case"
    ,   "of"
    ,   "class"
    ,   "data"
    ,   "default"
    ,   "deriving"
    ,   "do"
    ,   "forall"
    ,   "foreign"
    ,   "hiding"
    ,   "if"
    ,   "then"
    ,   "else"
    ,   "import"
    ,   "infix"
    ,   "infixl"
    ,   "infixr"
    ,   "instance"
    ,   "let"
    ,   "in"
    ,   "mdo"
    ,   "module"
    ,   "newtype"
    ,   "qualified"
    ,   "type"
    ,   "where"]

keywordDescrs :: [Descr]
keywordDescrs = map (\s -> Real $ RealDescr
                                s
                                Nothing
                                Nothing
                                Nothing
                                (Just (BS.pack "Haskell keyword"))
                                KeywordDescr
                                True) keywords

misc :: [(Text, String)]
misc = [ ("--", "Haskell comment")
       , ("=" , "Haskell definition")
       , ("\\", "Haskell lambda")
       , ("->", "Haskell arrow")
       , ("<-", "Haskell arrow")
       , ("::", "Haskell type definition")]

miscDescrs :: [Descr]
miscDescrs = map (\(s, d) -> Real $ RealDescr
                                s
                                Nothing
                                Nothing
                                Nothing
                                (Just (BS.pack d))
                                KeywordDescr
                                True) misc

extensionDescrs :: [Descr]
extensionDescrs =  map (\ext -> Real $ RealDescr
                                    (T.pack $ "X" ++ show ext)
                                    Nothing
                                    Nothing
                                    Nothing
                                    (Just (BS.pack "Haskell language extension"))
                                    ExtensionDescr
                                    True)
                                ([minBound..maxBound]::[KnownExtension])

moduleNameDescrs :: PackageDescr -> [Descr]
moduleNameDescrs pd = map (\md -> Real $ RealDescr
                                    (T.pack . display . modu $ mdModuleId md)
                                    Nothing
                                    (Just (mdModuleId md))
                                    Nothing
                                    (Just (BS.pack "Module name"))
                                    ModNameDescr
                                    True) (pdModules pd)

addOtherToScope ::  SymbolTable alpha  =>  PackScope alpha -> Bool -> PackScope alpha
addOtherToScope (PackScope packageMap symbolTable) addAll = PackScope packageMap newSymbolTable
    where newSymbolTable = foldl' (\ map' descr -> symInsert (dscName descr) [descr] map')
                        symbolTable (if addAll
                                        then keywordDescrs ++ extensionDescrs ++ modNameDescrs ++ miscDescrs
                                        else modNameDescrs)
          modNameDescrs = concatMap moduleNameDescrs (Map.elems packageMap)

