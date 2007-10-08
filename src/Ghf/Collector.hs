-----------------------------------------------------------------------------
--
-- Module      :  Ghf.Collector
-- Copyright   :  (c) Juergen Nicklisch-Franken (aka Jutaro)
-- License     :  GNU-GPL
--
-- Maintainer  :  Juergen Nicklisch-Franken <jnf at arcor.de>
-- Stability   :  experimental
-- Portability :  portable
--
-- | This modulle collects information for packages to make navigation and information
--  accessible to ghf
--
-------------------------------------------------------------------------------

import GHC
import Module
import TcRnMonad
import qualified Maybes as M
import ErrUtils
import HscTypes
import Finder
import LoadIface
import Outputable hiding(trace)
import qualified Pretty as P
import MkIface
import Config
import DynFlags
import PrelNames

import Distribution.InstalledPackageInfo
import Control.Monad.Reader
import UniqFM
import Packages
import System.IO
import System.Process
import Data.Maybe
import System.Console.GetOpt
import System.Environment
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import System.FilePath
import System.Directory
import Data.Char
import Data.List(isSuffixOf)

import Ghf.Core
import Ghf.Extractor
import Ghf.File


data Flag =  OpenFile
       deriving Show

options :: [OptDescr Flag]
options = [ ]

ghfOpts :: [String] -> IO ([Flag], [String])
ghfOpts argv =
    case getOpt Permute options argv of
          (o,n,[]  ) -> return (o,n)
          (_,_,errs) -> ioError $userError $concat errs ++ usageInfo header options
    where header = "Usage: ghf [OPTION...] files..."

-- |Build the main window
main = defaultErrorHandler defaultDynFlags $do
    args            <-  getArgs
    (o,fl)          <-  ghfOpts args
    libDir          <-  getSysLibDir
    putStrLn $"libdir '" ++ normalise libDir ++ "'"
    session         <-  newSession JustTypecheck (Just libDir)
    dflags0         <-  getSessionDynFlags session
    setSessionDynFlags session dflags0
    let version     =   cProjectVersion
    collectorPath   <-  getCollectorPath version
    knownPackages   <-  findKnownPackages collectorPath
    putStrLn $ "found known packages" ++ " " ++ show knownPackages
    packageInfos    <-  getInstalledPackageInfos session
--    putStrLn $ "get installed package infos" ++ " " ++ concatMap (\pi -> show (pkgName (package pi)))
--                                                            packageInfos
    let newPackages =   filter (\pi -> not $Set.member (showPackageId $ package pi) knownPackages)
                                    packageInfos
--    putStrLn $ "after new Package"
    let newPackages2 =  filter (\pi -> True {--pkgName (package pi) == "base"--}) newPackages
--    putStrLn $ "after new Package2, Remaining " ++ concatMap (\ pi -> show (pkgName (package pi)))
--                                                            newPackages2
    exportedIfaceInfos <-  mapM (\ info -> getIFaceInfos info session exposedModules)
                                    newPackages2
    hiddenIfaceInfos   <-  mapM (\ info -> getIFaceInfos info session hiddenModules)
                                    newPackages2
--    putStrLn $ "getIfaceInfos completed hidden lengtgh: " ++ show (map length hiddenIfaceInfos)
    let extracted   =   map extractInfo (zip3 exportedIfaceInfos hiddenIfaceInfos newPackages2)
--    putStrLn $ "extracted " ++ concatMap (\ pi -> packageId pi) extracted
    mapM_ (writeExtracted collectorPath) extracted


getIFaceInfos :: InstalledPackageInfo -> Session ->
                    (InstalledPackageInfo -> [String]) -> IO [(ModIface, FilePath)]
getIFaceInfos installedPackageInfo session selector = do
    let pckg   =    package installedPackageInfo
    let isBase =    pkgName pckg == "base"
    let ifaces =    mapM (\mn -> findAndReadIface empty
                          (if isBase
                                then mkBaseModule_ (mkModuleName mn)
                                else mkModule (mkPackageId pckg) (mkModuleName mn))
                          False) (selector installedPackageInfo)
    hscEnv <- sessionHscEnv session
    let gblEnv = IfGblEnv { if_rec_types = Nothing }
    maybes <- initTcRnIf  'i' hscEnv gblEnv () ifaces
    let res = catMaybes (map handleErr maybes)
    return res
    where
        handleErr (M.Succeeded val)   =   Just val
        handleErr (M.Failed mess)     =   trace (P.render (mess defaultErrStyle)) Nothing

findKnownPackages :: FilePath -> IO (Set String)
findKnownPackages filePath = do
    paths <- getDirectoryContents filePath
    let nameList = map dropExtension  $filter (\s -> ".pack" `isSuffixOf` s) paths
    return (Set.fromList nameList)

writeExtracted :: FilePath -> PackageDescr -> IO ()
writeExtracted dirPath pd = do
    let filePath = dirPath </> showPackageId (packageIdW pd) ++ ".pack"
    hdl <- openFile filePath WriteMode
    hPutStr hdl (show pd)
    hClose hdl

