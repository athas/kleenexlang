{-# LANGUAGE TypeOperators #-}
module Main where

import Control.Monad (when)
import Data.Word
import System.Environment
import System.Exit (ExitCode(..), exitWith)
import System.FilePath (splitFileName, dropExtension, replaceExtension)
    
import KMC.Expression hiding (Var)
import KMC.FSTConstruction hiding (Var)
import KMC.OutputTerm
import KMC.Program.Backends.C
import KMC.Program.IL
import KMC.RangeSet
import KMC.SSTCompiler
import KMC.SSTConstruction
import KMC.SymbolicSST
import KMC.Syntax.Config
import KMC.Syntax.Parser
import KMC.Hased.Parser
import KMC.Hased.Lang



type DFST sigma delta = SST (PathTree Var Int) (RangeSet sigma) (OutputTerm sigma delta) Var

sstFromFancy :: (Bounded sigma, Enum sigma, Ord sigma) =>
                String
                -> DFST sigma Bool
sstFromFancy str =
  case parseRegex fancyRegexParser str of
    Left e -> error e
    Right (_, re) -> optimize $ sstFromFST $ fromMu $ fromRegex re
                  
progFromFancy :: String -> Program Bool
progFromFancy str = compileAutomaton (sstFromFancy str :: DFST Word8 Bool)

cFromFancy :: String -> String
cFromFancy str =
  renderProgram UInt8T $ compileAutomaton (sstFromFancy str :: DFST Word8 Bool)

compileFancy :: String -> IO ExitCode
compileFancy str =
  compileProgram UInt8T (compileAutomaton (sstFromFancy str :: DFST Word8 Bool)) "match" Nothing

sstFromHased :: String -> SST (PathTree Var Int) (RangeSet Word8) HasedOutTerm Var
sstFromHased str = 
    case parseHased str of
      Left e -> error e
      Right ih -> optimize $ sstFromFST (fromMu (hasedToMuTerm ih))

progFromHased :: String -> Program Word8
progFromHased = compileAutomaton . sstFromHased

cFromHased :: String -> String
cFromHased = renderProgram UInt8T . progFromHased 
                 
runSST :: String -> [Char] -> Stream [Bool]
runSST str = run (sstFromFancy str)

main :: IO ExitCode
main = do
  args <- getArgs
  when (length args /= 1) $ do
    prog <- getProgName
    putStrLn $ "Usage: " ++ prog ++ " <hased_file>"
    exitWith $ ExitFailure 1
  let [hasedFile] = args
  hased <- readFile hasedFile
  let binFile = snd $ splitFileName $ dropExtension hasedFile
  let cFile   = replaceExtension hasedFile "c"
  putStrLn $ "Writing binary " ++ binFile ++ " and C source " ++ cFile
  compileProgram UInt8T (progFromHased hased) binFile (Just cFile)
