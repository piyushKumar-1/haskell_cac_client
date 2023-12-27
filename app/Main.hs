{-# LANGUAGE ForeignFunctionInterface #-}

module Main where

import Foreign
import Foreign.C

foreign import ccall "init_cac_clients" init_cac_clients :: CString -> CULong -> Bool -> Ptr CString -> CInt -> IO (Ptr CULong)
foreign import ccall "are_client_created" areClientsCreated :: CULong -> IO (Ptr Bool)
foreign import ccall "eval_ctx" eval_ctx :: CString -> CString -> IO (Ptr CString)
foreign import ccall "&free_json_data" free_json_data :: FunPtr (Ptr CString -> IO ())

initCacClients :: CString -> CULong -> Bool -> Ptr CString -> CInt -> IO (ForeignPtr CULong)
initCacClients a b c d e = do
  resPtr <- init_cac_clients a b c d e
  newForeignPtr_ resPtr

evalCtx :: CString -> CString -> IO (ForeignPtr CString) 
evalCtx tenant context = do 
  resPtr <- eval_ctx tenant context 
  newForeignPtr free_json_data resPtr

main :: IO ()
main = print "hellow"
