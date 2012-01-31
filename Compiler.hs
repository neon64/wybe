--  File     : Compiler.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Tue Jan 31 16:37:48 2012
--  Purpose  : 
--  Copyright: � 2012 Peter Schachte.  All rights reserved.
--

module Compiler (processFile, compiler) where

import Options   (Options, optVerbosity)
import AST       (Compiler, runCompiler, parseTree, modul, 
                  optionallyPutStr, reportErrors)
import Parser    (parse)
import Scanner   (inputTokens, fileTokens)
import Normalise (normalise)
import Types     (typeCheck)
import System.FilePath 
                 (takeBaseName)
import Data.List (intercalate)

processFile :: Options -> String -> IO ()
processFile opts file = do
  toks <- if file == "-" then inputTokens else fileTokens file
  let modname = if file == "-" then "stdin" else takeBaseName file
  let parseTree = parse toks
  modul <- runCompiler opts parseTree modname Nothing Nothing compiler
  return ()



compiler :: Compiler ()
compiler = do
    optionallyPutStr ((>0) . optVerbosity)
      $ intercalate "\n" . map show . parseTree
    normalise
    optionallyPutStr ((>0) . optVerbosity) (show . modul)
--    handleImports
--    flowCheck
    typeCheck
    reportErrors
