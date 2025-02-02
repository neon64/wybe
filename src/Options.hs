--  File     : Options.hs
--  Author   : Peter Schachte
--  Purpose  : Handle compiler options/switches
--  Copyright: (c) 2012 Peter Schachte.  All rights reserved.
--  License  : Licensed under terms of the MIT license.  See the file
--           : LICENSE in the root directory of this project.
--
----------------------------------------------------------------
--                      Compiler Options
----------------------------------------------------------------

-- |The wybe compiler command line options.
module Options (Options(..), LogSelection(..), handleCmdline, defaultOptions) where

import           Data.List             as List
import           Data.List.Extra
import           Data.Map              as Map
import           Data.Set              as Set
import           Data.Either           as Either
import           Control.Monad 
import           System.Console.GetOpt
import           System.Environment
import           System.Exit
import           System.FilePath
import           Version
import           System.Directory
import           System.Console.ANSI

-- |Command line options for the wybe compiler.
data Options = Options
    { optForce        :: Bool     -- ^Compile specified files even if up to date
    , optForceAll     :: Bool     -- ^Compile all files even if up to date
    , optShowVersion  :: Bool     -- ^Print compiler version and exit
    , optHelpLog      :: Bool     -- ^Print log option help and exit
    , optShowHelp     :: Bool     -- ^Print compiler help and exit
    , optLibDirs      :: [String] -- ^Directories where library files live
    , optLogAspects   :: Set LogSelection
                                  -- ^Which aspects to log
                                 
    , optLogUnknown   :: Set String
                                  -- ^Unknown log aspects
    , optNoLLVMOpt    :: Bool     -- ^Don't run the LLVM optimisation passes
    , optNoMultiSpecz :: Bool     -- ^Disable multiple specialization
    , optDumpLib      :: Bool     -- ^Also dump wybe.* modules when dumping
    , optVerbose      :: Bool     -- ^Be verbose in compiler output
    , optNoFont       :: Bool     -- ^Disable ISO font change codes in messages
    , optNoVerifyLLVM :: Bool     -- ^Don't run LLVM verification
    , optDumpOptLLVM  :: Bool     -- ^Dump optimised LLVM code
    } deriving Show


-- |Defaults for all compiler options
defaultOptions :: Options
defaultOptions = Options
  { optForce        = False
  , optForceAll     = False
  , optShowVersion  = False
  , optHelpLog      = False
  , optShowHelp     = False
  , optLibDirs      = []
  , optLogAspects   = Set.empty
  , optLogUnknown   = Set.empty
  , optNoLLVMOpt    = False
  , optNoMultiSpecz = False 
  , optDumpLib      = False
  , optVerbose      = False
  , optNoFont       = False
  , optNoVerifyLLVM = False
  , optDumpOptLLVM  = False
  }

-- |All compiler features we may want to log
data LogSelection =
  All | AST | BodyBuilder | Builder | Clause | Expansion | FinalDump
  | Flatten | Normalise | Optimise | Resources | Types
  | Unbranch | Codegen | Blocks | Emit | Analysis | Transform | Uniqueness
  deriving (Eq, Ord, Bounded, Enum, Show, Read)

allLogSelections :: [LogSelection]
allLogSelections = [minBound .. maxBound]


logSelectionDescription :: LogSelection -> String
logSelectionDescription All
    = "Log all aspects of the compilation process"
logSelectionDescription AST
    = "Log operations on the AST or IR"
logSelectionDescription BodyBuilder
    = "Log building up of proc bodies"
logSelectionDescription Builder
    = "Log the build process"
logSelectionDescription Clause
    = "Log generation of clausal form"
logSelectionDescription Expansion
    = "Log inlining and similar optimisations"
logSelectionDescription Flatten
    = "Log flattening of expressions"
logSelectionDescription FinalDump
    = "Log a dump of the final AST produced"
logSelectionDescription Optimise
    = "Log optimisation"
logSelectionDescription Normalise
    = "Log normalised items"
logSelectionDescription Resources
    = "Log handling of resources"
logSelectionDescription Types
    = "Log type checking"
logSelectionDescription Unbranch
    = "Log transformation of loops and selections into clausal form"
logSelectionDescription Codegen
    = "Log generation of LLVM code"
logSelectionDescription Blocks
    = "Log translation of LPVM procedures into LLVM"
logSelectionDescription Emit
    = "Log emission of LLVM IR from the definitions created"
logSelectionDescription Analysis
    = "Log analysis of LPVM IR"
logSelectionDescription Transform
    = "Log transform of mutate instructions"
logSelectionDescription Uniqueness
    = "Log uniqueness checking"

-- |Command line option parser and help text
options :: [OptDescr (Options -> Options)]
options =
 [ Option ['f']     ["force"]
     (NoArg (\ opts -> opts { optForce = True }))
   "force compilation of specified files"
 , Option []        ["force-all"]
     (NoArg (\ opts -> opts { optForceAll = True }))
   "force compilation of all dependencies"
 , Option ['L']     ["libdir"]
   (ReqArg (\ d opts -> opts { optLibDirs = optLibDirs opts ++ [d] }) "DIR")
         ("specify a library directory [default $WYBELIBS or " ++ libDir ++ "]")
 , Option ['l']     ["log"]
   (ReqArg addLogAspects "ASPECT")
         "add comma-separated aspects to log, or 'all'"
 , Option []        ["log-help"]
     (NoArg (\ opts -> opts { optHelpLog = True }))
     "display help on logging options and exit"
 , Option ['V']     ["version"]
     (NoArg (\ opts -> opts { optShowVersion = True }))
     "show version number"
 , Option ['h']     ["help"]
     (NoArg (\ opts -> opts { optShowHelp = True }))
     "display this help text and exit"
 , Option ['s']     ["no-llvm-opt"]
     (NoArg (\opts -> opts { optNoLLVMOpt = True }))
     "don't run the LLVM optimisation pass manager on the emitted LLVM"
 , Option []     ["no-multi-specz"]
     (NoArg (\opts -> opts { optNoMultiSpecz = True }))
     "disable multiple specialization"
 , Option []     ["dump-lib"]
     (NoArg (\opts -> opts { optDumpLib = True }))
     "Also dump wybe library when dumping"
 , Option ['v']     ["verbose"]
     (NoArg (\opts -> opts { optVerbose = True }))
     "dump verbose messages after compilation"
 , Option ['n'] ["no-fonts"]
     (NoArg (\opts -> opts { optNoFont = True }))
     "disable font highlighting in messages"
 , Option [] ["no-verify-llvm"]
     (NoArg (\opts -> opts { optNoVerifyLLVM = True }))
     "disable verification of generated LLVM code"
 , Option [] ["dump-opt-llvm"]
     (NoArg (\opts -> opts { optDumpOptLLVM = True }))
     "dump optimised LLVM code"
 ]


-- |Help text header string
header :: String
header = "Usage: wybemk [OPTION...] targets..."

-- |Parse command line arguments
compilerOpts :: [String] -> IO (Options, [String])
compilerOpts argv =
  case getOpt Permute options argv of
    (o,n,[]  ) -> return (List.foldl (flip id) defaultOptions o, n)
    (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))

-- |Parse the command line and handle all options asking to print
--  something and exit.
handleCmdline :: IO (Options, [String])
handleCmdline = do
    argv <- getArgs
    assocList <- getEnvironment
    let env = Map.fromList assocList
    (opts0,files) <- compilerOpts argv
    let libs0 = case optLibDirs opts0 of
                [] -> maybe [libDir] splitSearchPath $ Map.lookup "WYBELIBS" env
                lst -> lst
    libs <- mapM makeAbsolute libs0
    let opts = opts0 { optLibDirs = libs }
    if optShowHelp opts
    then do
        putStrLn $ usageInfo header options
        exitSuccess
    else let unknown = optLogUnknown opts
             badLogs = not $ Set.null unknown
         in if optHelpLog opts || badLogs
    then do
        putStrLn "Use the -l or --log option to select logging to stdout."
        putStrLn "The argument to this option should be a comma-separated"
        putStrLn "list (with no spaces) of these options:"
        putStr $ formatMapping logSelectionDescription
        when badLogs $ do
            unless (optNoFont opts) $ setSGR [SetColor Foreground Vivid Red]
            putStrLn $ "\nError: Unknown log options: " 
                               ++ intercalate ", " (Set.toList unknown)
        if badLogs then exitFailure else exitSuccess
    else if optShowVersion opts
    then do
        putStrLn $ "wybemk " ++ version ++ " (git " ++ gitHash ++ ")"
        putStrLn $ "Built " ++ buildDate
        putStrLn $ "Using library directories:\n    " ++
            intercalate "\n    " (optLibDirs opts)
        exitSuccess
    else if List.null files
    then do
        putStrLn $ usageInfo header options
        exitFailure
    else do
        return (opts,files)


addLogAspects :: String -> Options -> Options
addLogAspects aspectsStr opts@Options{optLogUnknown=unknown0, 
                                      optLogAspects=aspects0} = 
    let aspectList = separate ',' aspectsStr
        (unknown', aspects') = partitionEithers $ getLogRequest <$> aspectList 
        unknown'' = Set.fromList unknown'
        aspects'' = let aspectSet = Set.fromList aspects'
                    in if Set.member All aspectSet 
                       then Set.fromList allLogSelections else aspectSet
    in opts{optLogUnknown=unknown0 `Set.union` unknown'',
            optLogAspects=aspects0 `Set.union` aspects''}

getLogRequest :: String -> Either String LogSelection
getLogRequest selection = maybe (Left selection) Right $ logMap Map.!? lower selection
  where
    logMap = Map.fromList [(lower $ show s, s) | s <- allLogSelections]


-- |The inverse of intercalate:  split up a list into sublists separated
--  by the separator list.
separate :: Eq a => a -> [a] -> [[a]]
separate separator [] = [[]]
separate separator (e:es) =
  if e == separator
  then []:separate separator es
  else let (s:ss) = separate separator es
       in  (e:s):ss


-- |Produce a table showing the domain and range of the input function and
formatMapping :: (Bounded a, Enum a, Show a) => (a -> String) -> String
formatMapping mapping =
    let domain = [minBound .. maxBound]
        width = 2 + maximum (List.map (length . show) domain)
    in  unlines $
        [ let t = show elt
          in  replicate (width - length t) ' ' ++ t ++ " : " ++ mapping elt
        | elt <- domain]
