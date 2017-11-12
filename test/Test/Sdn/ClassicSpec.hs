{-# LANGUAGE Rank2Types #-}

-- | Tests for classic paxos.

module Test.Sdn.ClassicSpec
    ( spec
    ) where

import           Universum

import           Control.TimeWarp.Logging (setLoggerName, usingLoggerName)
import           Control.TimeWarp.Rpc     (runPureRpc)
import qualified Control.TimeWarp.Rpc     as D
import           Control.TimeWarp.Timed   (runTimedT)
import           Data.Default
import           System.Random            (mkStdGen, split)
import           Test.Hspec               (Spec, describe)
import           Test.Hspec.QuickCheck    (prop)
import           Test.QuickCheck          (Property, forAll, property)
import           Test.QuickCheck.Monadic  (monadicIO, stop)
import           Test.QuickCheck.Property (failed, reason, succeeded)

import           Sdn.Extra
import           Sdn.Protocol
import qualified Sdn.Schedule             as S
import           Test.Sdn.Properties
import           Test.Sdn.Util

spec :: Spec
spec = describe "classic" $ do
    prop "simple" $
        -- launch with default test settings
        -- see @instance Default TestLaunchParams@ below for their definition
        testLaunch def

    prop "acceptor unavailable" $
        testLaunch def
        { testDelays =
              D.forAddress (processAddress (Acceptor 1))
                  D.blackout
        }

    prop "too many acceptors unavailable" $
        testLaunch def
        { testDelays =
              D.forAddressesList (processAddress . Acceptor <$> [1, 2])
                  D.blackout
        , testProperties =
              [ fails (eventually proposedPoliciesWereLearned)
              ]
        }


data TestLaunchParams = TestLaunchParams
    { testLauncher   :: TopologyLauncher
    , testSettings   :: TopologySettings
    , testDelays     :: D.Delays
    , testProperties :: forall m. MonadIO m => [ProtocolProperty m]
    }

instance Default TestLaunchParams where
    def = TestLaunchParams
        { testLauncher = launchClassicPaxos
          -- ^ use Classic Paxos protocol
        , testSettings = def
          -- ^ default topology settings allow to execute
          -- 1 ballot with 1 policy proposed
        , testDelays = D.steady
          -- ^ no message delays
        , testProperties = basicProperties
          -- ^ set of reasonable properties for any good consensus launch
        }

testLaunch :: TestLaunchParams -> Property
testLaunch TestLaunchParams{..} =
    forAll arbitraryRandom $ \seed -> do
        let (gen1, gen2) =
                split (mkStdGen seed)
            launch =
                testLauncher
                testSettings { topologySeed = S.FixedSeed gen2 }
            runEmulation =
                runTimedT .
                runPureRpc testDelays gen1 .
                usingLoggerName mempty

        ioToProperty $ do
            -- launch silently
            outcome <- runEmulation $ do
                monitor <- setDropLoggerName launch
                protocolProperties monitor testProperties
            -- if failed - relaunch with logs and then return error
            case outcome of
                Right () -> pure $ property succeeded
                Left err -> do
                    runEmulation . setLoggerName mempty $
                        awaitTermination =<< launch
                    return $ property failed{ reason = toString err }

  where
    ioToProperty :: IO Property -> Property
    ioToProperty propM = monadicIO $ stop =<< lift propM

