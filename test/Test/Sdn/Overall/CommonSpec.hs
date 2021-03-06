{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Common properties for classic and fast versions of algorithm.

module Test.Sdn.Overall.CommonSpec
    ( spec
    ) where

import           Universum

import qualified Control.TimeWarp.Rpc        as D
import           Control.TimeWarp.Timed      (Millisecond, Second, hour, interval, sec)
import           Data.Default
import           Data.Typeable               (typeRep)
import           Test.Hspec                  (Spec, describe)
import           Test.Hspec.QuickCheck       (prop)
import           Test.QuickCheck             (Positive (..), Small (..), arbitrary, oneof,
                                              (==>))

import           Sdn.Base
import qualified Sdn.Extra.Schedule          as S
import           Sdn.Policy.Fake
import           Sdn.Protocol
import           Test.Sdn.Overall.Launcher
import           Test.Sdn.Overall.Properties

spec :: Spec
spec = describe "common" $ do

    let checkVersion
            :: (HasVersionTopologyActions pv, Default (CustomTopologySettings pv), Typeable pv)
            => Proxy pv -> Spec
        checkVersion (pv :: Proxy pv) = do

          -- artifical scenarious which check whether protocol at least slightly works
          describe "primitive cases" $ do

            prop "simple" $
                -- launch with default test settings
                -- search for @instance Default TestLaunchParams@ for their definition
                -- generally default config is simpliest one - no network delays,
                -- 1 ballot and 1 policy proposed, most basic properties checked.
                -- see 'Test.Sdn.Overall.Launcher' module for details.
                testLaunch @pv def

            -- check for classic version only, for fast version there is a special case of this
            when (typeRep pv == typeRep (Proxy @Classic)) $
                prop "acceptor unavailable" $
                    testLaunch @pv def
                    { testDelays =
                        D.forAddress (processAddress (Acceptor 1))
                            D.blackout
                    }

            prop "too many acceptors unavailable" $
                testLaunch @pv def
                { testDelays =
                    D.forAddressesList (processAddress . Acceptor <$> [1, 2])
                        D.blackout
                , testProperties =
                    [ fails (eventually proposedPoliciesWereLearned)
                    ]
                }

            prop "good and bad policies" $
                -- TODO: optimize algorithm and get rid of 'Small'
                \(Small (n :: Word)) ->

                testLaunch @pv def
                { testSettings = defTopologySettings
                    { topologyProposalSchedule = do
                        S.times n
                        S.generate . oneof $
                            [ GoodPolicy <$> arbitrary
                            , BadPolicy <$> arbitrary
                            ]
                    }
                }

            prop "all conflicting policies" $
                \(Positive (Small n :: Small Word)) ->

                testLaunch @pv def
                { testSettings = defTopologySettings
                    { topologyProposalSchedule = do
                        S.times n
                        S.generate (BadPolicy <$> arbitrary)
                    }
                , testProperties =
                    [ invariant learnedPoliciesWereProposed
                    , eventually learnersAgree
                    , eventually $ numberOfLearnedPolicies _Accepted (== 1)
                    ]
                }


            prop "network delays" $
                testLaunch @pv def
                { testDelays = D.uniform (0, 1 :: Second)
                , testSettings = def
                    { topologyBallotsSchedule = S.delayed (interval 2 sec)
                      -- not to miss proposed policy
                    }
                }

            prop "temporaly no quorum of acceptors is accessible" $
                testLaunch @pv def
                { testDelays =
                    D.forAddressesList (processAddress . Acceptor <$> [1, 2]) $
                        D.temporal (interval 15 sec) $
                        D.blackout
                , testSettings = def
                    { topologyLifetime = interval 30 sec
                    , topologyBallotsSchedule = S.periodic (interval 10 sec)
                    , topologyProposerInsistance = \balSchedule -> balSchedule
                    }
                }

          -- bunch of complex scenarious involving introduction of many policies
          describe "real life cases" $

            prop "no conflicts" $
            \(Positive (Small proposalsNum :: Small Word)) ->
            \(Positive (Small balDelay)) ->
            proposalsNum > balDelay ==>

                testLaunch @pv def
                { testSettings = defTopologySettings
                    { topologyProposalSchedule = do
                        S.repeating proposalsNum (interval 1 sec)
                        S.generate (GoodPolicy <$> arbitrary)
                    , topologyBallotsSchedule = mconcat
                        [ S.repeating
                            (proposalsNum `div` balDelay)
                            (interval (fromIntegral balDelay) sec)
                        , finalBallot
                        ]
                    }
                , testDelays = D.uniform (0, 50 :: Millisecond)
                }


    describe "classic" $
        checkVersion $ Proxy @Classic
    describe "fast" $
        checkVersion $ Proxy @Fast

  where
    -- one final ballot for all proposals which weren't made in time
    finalBallot :: MonadTopology m => S.Schedule m ()
    finalBallot = S.delayed (interval 1 hour)
