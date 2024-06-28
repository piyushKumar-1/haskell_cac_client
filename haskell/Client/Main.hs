{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wwarn=identities #-}

module Client.Main where

import Control.Concurrent
import Data.Aeson as DA
import Data.Aeson.Key as DAK
import qualified Data.Aeson.KeyMap as DAKM
import Data.Aeson.KeyMap as KM

import qualified Data.ByteString.Lazy.Char8 as BS
import Data.HashMap.Strict as HashMap
import Data.Maybe
import Data.Text as Text
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LTE
import Foreign
import Foreign.C
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Prelude as P
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Control.Monad
import System.Environment as Se
import GHC.Generics
import qualified Data.ByteString.Lazy.Char8 as  DB
import Data.Text.Encoding as DT
import Control.Lens.Combinators
import Control.Lens.Fold
import Data.Aeson.Lens
import qualified Data.Vector as DV
import Data.Time.Clock
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent
import Data.Bool as B

foreign import ccall "init_cac_clients" init_cac_clients :: CString -> CULong -> Ptr CString -> CInt -> CBool -> IO  CInt

foreign import ccall "eval_ctx" eval_ctx :: CString -> CString -> IO (Ptr CChar)

foreign import ccall "&free_json_data" free_json_data :: FunPtr (Ptr CChar -> IO ())

foreign import ccall "init_superposition_clients" init_superposition_clients :: CString -> CULong -> Ptr CString -> CInt -> CBool -> IO CInt

foreign import ccall "eval_experiment" eval_experiment :: CString -> CString -> CInt -> IO (Ptr CChar)

foreign import ccall "run_polling_updates" run_polling_updates :: CString -> IO ()

foreign import ccall "start_polling_updates" start_polling_updates :: CString -> IO ()

foreign import ccall "get_variants" get_variants :: CString -> CString -> CInt -> IO (Ptr CChar)

foreign import ccall "is_experiments_running" is_experiments_running :: CString -> IO CInt

foreign import ccall "create_client_from_config" create_client_from_config :: CString -> CULong -> CString -> CString -> IO CInt

initCacClients :: CString -> CULong -> Ptr CString -> CInt -> CBool ->  IO  CInt
initCacClients hostname polling_interval_secs tenants tenants_count enable_polling = do
  init_cac_clients hostname polling_interval_secs tenants tenants_count enable_polling

initSuperPositionClients :: CString -> CULong -> Ptr CString -> CInt -> CBool -> IO CInt
initSuperPositionClients hostname polling_interval tenants tenants_count enable_polling = do
  init_superposition_clients hostname polling_interval tenants tenants_count enable_polling

isExperimentsRunning :: String -> IO Bool
isExperimentsRunning tenant = do
  tenant' <- stringToCString tenant
  res <- is_experiments_running tenant'
  return $ res == 1


getVariants :: String -> String -> Int -> IO Value
getVariants tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- get_variants tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ toJSON result

getVariants' :: String -> [(Text,Value)] -> Int -> IO Value
getVariants' tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- hashMapToString (HashMap.fromList context) >>= stringToCString
  resPtr <- get_variants tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ toJSON result

evalCtx :: String -> String -> IO (Either String Object)
evalCtx tenant context = do
  putStrLn $ "evalCtx called with tenant: " <> tenant <> " and context: " <> context
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- eval_ctx tenant' context'
  resPtr' <- freeJsonData resPtr
  withForeignPtr resPtr' peekCString >>= putStrLn
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ convertTextToObject result

-- evalExperiment :: String -> String -> Int -> IO (Either String Object)
-- evalExperiment tenant context toss = do
--   tenant' <- stringToCString tenant
--   context' <- stringToCString context
--   resPtr <- eval_experiment tenant' context' $ fromIntegral toss
--   resPtr' <- freeJsonData resPtr
--   result <- withForeignPtr resPtr' cStringToText
--   return $ convertTextToObject (makeNull result)

evalExperiment :: String -> [(Text,Value)] -> Int -> IO String
evalExperiment tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- hashMapToString (HashMap.fromList context) >>= stringToCString
  resPtr <- eval_experiment tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ Text.unpack $ makeNull result

freeJsonData :: Ptr CChar -> IO (ForeignPtr CChar)
freeJsonData ptr = do
  newForeignPtr free_json_data ptr

stringToCString :: String -> IO CString
stringToCString = newCString

printForeignPtr :: ForeignPtr CULong -> IO ()
printForeignPtr fptr = do
  let ptr = unsafeForeignPtrToPtr fptr
  culongValue <- peek ptr
  putStrLn $ "CULong value: " ++ show culongValue

hashMapToString :: MyHashMap -> IO String
hashMapToString hashMap = pure $ Text.unpack . LT.toStrict . LTE.decodeUtf8 . encode $ hashMap

-- stringToCString (unpack json)

type MyHashMap = HashMap Text DA.Value

defaultHashMap :: MyHashMap
defaultHashMap = HashMap.fromList [(pack "defualt", DA.String (Text.pack "default"))]

cStringToText :: CString -> IO Text
cStringToText cStr = pack <$> peekCString cStr

-- Parse Text to HashMap
parseJsonToHashMap :: Text -> Maybe MyHashMap
parseJsonToHashMap = DA.decode . BS.fromStrict . encodeUtf8

initCACClient :: String -> Int -> [String] -> Bool -> IO Int
initCACClient host interval tenants enablePolling = do
  let tenantsCount = P.length tenants
  arr1 <- mapM stringToCString tenants
  arr2 <- newArray arr1
  host' <- stringToCString host
  x <- initCacClients host' (fromIntegral interval) arr2 (fromIntegral tenantsCount) (fromBool enablePolling)
  return $ fromIntegral x

initSuperPositionClient :: String -> Int -> [String] -> Bool -> IO Int
initSuperPositionClient host interval tenants enablePolling = do
  let tenantsCount = P.length tenants
  arr1 <- mapM stringToCString tenants
  arr2 <- newArray arr1
  host' <- stringToCString host
  x <- initSuperPositionClients host' (fromIntegral interval) arr2 (fromIntegral tenantsCount) (fromBool enablePolling)
  return $ fromIntegral x

runSuperPositionPolling :: [String] -> IO ()
runSuperPositionPolling  tenants = do
  arr1 <- mapM stringToCString tenants
  mapM_ (forkOS . run_polling_updates) arr1

startCACPolling :: [String] -> IO ()
startCACPolling tenants = do
  arr1 <- mapM stringToCString tenants
  mapM_ ( forkOS . start_polling_updates) arr1

initializeClients :: (String, Int, [String], Bool) -> (String, Int, [String], Bool) -> IO Int
initializeClients (host1,interval1,tenants1,enablePolling1) (host2,interval2,tenants2, enablePolling2) = do
  _ <- initCACClient host1 interval1 tenants1 enablePolling1
  initSuperPositionClient host2 interval2 tenants2 enablePolling2

createClientFromConfig :: String -> Int -> String -> String -> IO Int
createClientFromConfig tenant interval  config hostname = do
  host' <- stringToCString hostname
  let interval' = fromIntegral interval
  tenant' <- stringToCString tenant
  config' <- stringToCString config
  status <- create_client_from_config tenant' interval'  config' host'
  return $ fromIntegral status

evalExperimentAsString :: String -> String -> Int -> IO String
evalExperimentAsString tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- eval_experiment tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ Text.unpack $ makeNull result

evalExperimentAsValue :: String -> String -> Int -> IO Value
evalExperimentAsValue tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- eval_experiment tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  finalizeForeignPtr resPtr'
  return $ toJSON result

dropPrefix :: Text.Text -> Key -> Key
dropPrefix key' config = maybe config DAK.fromText $ Text.stripPrefix key' (DAK.toText config)

getConfigFromCAC :: [(Text, Value)] -> String -> Int ->  String -> IO Value
getConfigFromCAC context tenant toss keyToDrop = do
  config <- evalExperiment tenant context toss
  let res'' = config ^@.. _Object . reindexed (dropPrefix (pack keyToDrop)) (itraversed . indices (Text.isPrefixOf (pack keyToDrop) . DAK.toText))  
      res' = makeValueNull <$> res''
  pure $ DA.Object (KM.fromList res')

getConfigListFromCAC :: [(Text, Value)] -> String -> Int ->  String -> String -> IO Value
getConfigListFromCAC context tenant toss keyToDrop key' = do
  config <- evalExperiment tenant context toss
  let res' = config ^@.. _Object . reindexed (dropPrefix (pack keyToDrop)) (itraversed . indices (Text.isPrefixOf (pack keyToDrop) . DAK.toText))  
      res''' = makeValueNull <$> res'
      res'' =
        fromMaybe
          (DA.Array (DV.fromList []))
          (DAKM.lookup (DAK.fromText (Text.pack key')) (DAKM.fromList res'))
  pure res''
  
makeValueNull :: (a, Value) -> (a, Value)
makeValueNull (a, String v)
  | v == pack "null" = (a, Null)
  | v == pack "Null" = (a, Null)
  | v == pack "None" = (a, Null)
makeValueNull obj = obj

makeNull :: Text -> Text 
makeNull txt = 
  let replaced = Text.replace (Text.pack "\"None\"") (Text.pack "null") txt
  in 
    Text.replace (Text.pack "\"Null\"") (Text.pack "null") replaced

convertTextToObject :: Text -> Either String Object
convertTextToObject txt = do
    let bs = BL.fromStrict $ TE.encodeUtf8 txt

    value <- eitherDecode' bs :: Either String Value

    -- Ensure Value is an Object
    case value of
        Object obj -> Right obj
        _ -> Left "Text does not represent a JSON object"
-- intiateClients :: {super, interval, d} -> forkingInterval -> -> IO ()

data AvgSpeedOfVechilePerKm = AvgSpeedOfVechilePerKm -- FIXME make datatype to [(Variant, Kilometers)]
  { sedan :: Kilometers,
    suv :: Kilometers,
    hatchback :: Kilometers,
    autorickshaw :: Kilometers,
    taxi :: Kilometers,
    taxiplus :: Kilometers
  }
  deriving (Generic, Show, FromJSON, ToJSON, Read)

newtype Kilometers = Kilometers
  { getKilometers :: Int
  }
  deriving newtype (Show, Read, Num, Eq, Ord, Enum, Real, Integral, FromJSON, ToJSON)

-- evalExperimentAsStringForked :: String -> String -> Int -> IO String
-- evalExperimentAsStringForked tenant context toss = do
--   tenant' <- stringToCString tenant
--   context' <- stringToCString context
--   resPtr <- forkOS $ eval_experiment tenant' context' $ fromIntegral toss
--   resPtr' <- freeJsonData resPtr
--   result <- withForeignPtr resPtr' cStringToText
--   return $ Text.unpack $ makeNull result

connect :: IO()
connect = do
    arr1 <- mapM stringToCString ["atlas_driver_offer_bpp_v2"]
    arr2 <- newArray arr1
    hostEnv <- Se.lookupEnv "HOST"
    host <- stringToCString "http://localhost:8080"
    x <- initCacClients host 10 arr2 (fromIntegral (P.length arr1)) (fromBool True)
    putStrLn $ "x: " <> show x
    y <- initSuperPositionClients host 1 arr2 (fromIntegral (P.length arr1)) (fromBool True)
    putStrLn $ "y: " <> show y
    case x of 
      0 -> mapM_  (forkOS . run_polling_updates) arr1
      _ -> putStrLn "Error in initializing CAC clients"
    case y of 
      0 -> mapM_ (forkOS . start_polling_updates) arr1
      _ -> putStrLn "Error in initializing SuperPosition clients"
    
    pure ()



helper1 :: IO ()
helper1  = do
  -- putStrLn "Starting"
  time <- getCurrentTime
  dpcCond <- hashMapToString $ HashMap.fromList [(pack "merchantOperatingCityId", String (pack "1e7b7ab9-3b9b-4d3e-a47c-11e7d2a9ff98"))]
  contextValue <- evalExperimentAsString "test" dpcCond 1
  -- putStrLn $ "contextValue: " <> show contextValue
  time' <- getCurrentTime
  when (realToFrac (diffUTCTime time' time) > 4.0) $
    putStrLn "Latency is greater than 40 seconds"

helper2 :: Int -> IO ()
helper2 n = do
  _ <- mapConcurrently (const helper1) [1..n]
  -- print latencies
  -- helper2 n
  pure ()




main :: IO ()
main = do
  -- putStrLn "Starting Haskell client..."
  -- _ <- forkOS connect
  -- _ <- forkOS connect
  -- time <- getCurrentTime
  -- _ <- helper2 100000
  -- time' <- getCurrentTime
  -- putStrLn $ "Total time taken: " <> show (diffUTCTime time' time)
  -- threadDelay 60000000
  _ <- connect
  lat <- helper2 100000
  -- putStrLn $ "Latency: " <> show lat
  -- cond <- hashMapToString $ HashMap.fromList [(pack "farePolicyId", DA.String (Text.pack "094112f5-4523-bb76-7697-d6cfd4905361"))]
  -- status <- createClientFromConfig "atlas_driver_offer_bpp_v2" 10  "{}" "https://api.sandbox.beckn.juspay.in/cac"
  -- case status of
  --   0 -> putStrLn "Client created successfully"
  --   _ -> putStr Ln "Error in creating client"
  -- let cond = "{}" :: String
  -- res <- evalExperiment "atlas_driver_offer_bpp_v2" cond 1
  -- contextValue <- evalExperiment "dev" cond 2
  -- putStrLn $ "contextValue: " <> show contextValue
  -- let objectify = contextValue
  -- case res of
  --   Left err -> putStrLn $ "Error: " <> err
  --   Right val -> do
  --     let ans = KM.filterWithKey (\key _ -> Text.pack "farePolicyProgressiveDetails:" `isPrefixOf` toText key) val
  --     let waitingCharge' = KM.lookup (DAK.fromString "farePolicyProgressiveDetails:waitingCharge") ans >>= fromJSONHelper
  --         freeWaitingTime' = KM.lookup (DAK.fromString "farePolicyProgressiveDetails:freeWatingTime") ans >>= fromJSONHelper
  --         waitingChargeInfo = WaitingChargeInfo <$> freeWaitingTime' <*> waitingCharge'
  --         waitingCharge''' = KM.lookup (DAK.fromString "farePolicyProgressiveDetails:waitingCharge") ans
  --     -- print waitingChargeInfo
  --     case waitingCharge''' of
  --       Just waitingCharge'' -> do
  --         case fromJSON waitingCharge'' :: Result WaitingCharge of
  --           Success a -> print a
  --           DA.Error err -> putStrLn $  "Error in parsing waiting charge" <> err
  --     print waitingCharge'
  --     print freeWaitingTime'
  --     print ans
  -- case res of
    -- Left err -> putStrLn $ "Error: " <> err
    -- Right val -> do
    -- Right (Object k) -> do
      -- let ans = KM.filterWithKey (\key _ -> Text.pack "driverPoolConfig:" `isPrefixOf` toText key) val
      -- putStrLn $ "shorted shit" <> show ans
    -- Right  something -> putStrLn $ "not object" <> show something
  -- _ <- run_polling_updates tenant1
  -- let x = "{\"contexts\": [],\"overrides\": {},\"default_configs\": {\n        \"merchantServiceUsageConfig:aadhaarVerificationService\": \"Gridline\",\n        \"merchantServiceUsageConfig:autoComplete\": \"Google\",\n        \"merchantServiceUsageConfig:createdAt\": \"2024-02-19 15:13:50.263530+00:00\",\n        \"merchantServiceUsageConfig:enableDashboardSms\": false,\n        \"merchantServiceUsageConfig:getDistances\": \"Google\",\n        \"merchantServiceUsageConfig:getDistancesForCancelRide\": \"OSRM\",\n        \"merchantServiceUsageConfig:getExophone\": \"Exotel\",\n        \"merchantServiceUsageConfig:getPickupRoutes\": \"Google\",\n        \"merchantServiceUsageConfig:getPlaceDetails\": \"Google\",\n        \"merchantServiceUsageConfig:getPlaceName\": \"Google\",\n        \"merchantServiceUsageConfig:getRoutes\": \"Google\",\n        \"merchantServiceUsageConfig:getTripRoutes\": \"Google\",\n        \"merchantServiceUsageConfig:initiateCall\": \"Exotel\",\n        \"merchantServiceUsageConfig:issueTicketService\": \"Kapture\",\n        \"merchantServiceUsageConfig:merchantId\": \"da4e23a5-3ce6-4c37-8b9b-41377c3c1a52\",\n        \"merchantServiceUsageConfig:merchantOperatingCityId\": \"6bc154f2-2097-fbb3-7aa0-969ced5962d5\",\n        \"merchantServiceUsageConfig:notifyPerson\": \"FCM\",\n        \"merchantServiceUsageConfig:smsProvidersPriorityList\": [\n            \"MyValueFirst\",\n            \"ExotelSms\",\n            \"GupShup\"\n        ],\n        \"merchantServiceUsageConfig:snapToRoad\": \"Google\",\n        \"merchantServiceUsageConfig:updatedAt\": \"2024-02-19 15:13:50.263530+00:00\",\n        \"merchantServiceUsageConfig:useFraudDetection\": false,\n        \"merchantServiceUsageConfig:whatsappProvidersPriorityList\": [\n            \"GupShu\"\n        ]\n    }\n}"
  -- _ <- createClientFromConfig "test" 10 x "http://localhost:8080"
  -- tenant1 <- stringToCString "dev"
  -- contextValue1 <- evalExperimentAsString "dev" cond 2
  -- let objectify = contextValue
  -- putStrLn $ "contextValue1: " <> show contextValue1
  -- tenant2 <- stringToCString "dev"
  
  -- let jsonString = case json' of
  --         DA.String str ->
  --           putStrLn $ "str: " <> 
  --           BL.fromStrict $  DT.encodeUtf8 str
  --         _ ->BL.fromStrict $  DT.encodeUtf8 $ Text.pack ""
  -- putStrLn $ "json: " <> show json'
  -- putStrLn $ "jsonString: " <> show jsonString
  -- let ans =  (decode jsonString) :: (Maybe AvgSpeedOfVechilePerKm)

  -- putStrLn $ "ans: " <> show ans
  -- value <- (hashMapToString (fromMaybe (HashMap.fromList [(pack "defaultKey", DA.String (Text.pack ("defaultValue")))]) contextValue))
  -- putStrLn $ "contextValueEvaluated: " <> show value
  -- result1 <- evalCtx tenant1 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  -- result2 <- evalCtx tenant2 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  -- let final1 = fromMaybe defaultHashMap $ parseJsonToHashMap result1
  -- let final2 = fromMaybe defaultHashMap $ parseJsonToHashMap result2
  -- putStrLn $ ("final1 is " <> show final1 <> " final2 is " <> show final2)
  -- _ <- evalCtx tenant context >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  -- context1 <- stringToCString "{merchantId\":\"random\"}"
  -- _ <- evalExperiment tenant context1 23 >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  putStrLn "created the clients and started polling updates..."
