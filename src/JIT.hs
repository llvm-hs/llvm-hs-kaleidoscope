{-# LANGUAGE OverloadedStrings #-}

module JIT
  ( run,
    runJIT,
  )
where

import Control.Monad.Except
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text.Lazy.IO as TIO
import Foreign.Ptr
  ( FunPtr,
    castFunPtr,
    castPtrToFunPtr,
    wordPtrToPtr,
  )
import qualified LLVM.AST as AST
import qualified LLVM.CodeGenOpt as CodeGenOpt
import qualified LLVM.CodeModel as CodeModel
import LLVM.Context
import LLVM.Module as Mod
import LLVM.OrcJIT
import LLVM.PassManager
import LLVM.Pretty
import qualified LLVM.Relocation as Reloc
import LLVM.Target

foreign import ccall "dynamic" haskFun :: FunPtr (IO Double) -> (IO Double)

run :: FunPtr a -> IO Double
run fn = haskFun (castFunPtr fn :: FunPtr (IO Double))

passes :: PassSetSpec
passes = defaultCuratedPassSetSpec {optLevel = Just 3}

runJIT :: AST.Module -> IO AST.Module
runJIT astmod = do
  TIO.putStrLn "Original:"
  TIO.putStrLn $ ppll astmod
  withContext $ \context ->
    withHostTargetMachine Reloc.PIC CodeModel.Default CodeGenOpt.Default $ \tm ->
      withModuleFromAST context astmod $ \m -> do
        optimized <- withPassManager passes $ flip runPassManager m
        when optimized $ putStrLn "\nOptimized"
        optmod <- moduleAST m
        s <- moduleLLVMAssembly m
        ByteString.putStrLn s
        withExecutionSession $ \es -> do
          let dylibName = "kaleidoscope"
          dylib <- createJITDylib es dylibName
          withClonedThreadSafeModule m $ \tsm -> do
            ol <- createRTDyldObjectLinkingLayer es
            il <- createIRCompileLayer es ol tm
            addModule tsm dylib il
            mainfn <- lookupSymbol es il dylib "main"
            case mainfn of
              Right (JITSymbol fPtr _) -> do
                res <- haskFun (castPtrToFunPtr (wordPtrToPtr fPtr))
                putStrLn $ "Evaluated to: " ++ show res
              Left (JITSymbolError msg) -> do
                print msg
            -- Return the optimized module
            return optmod
