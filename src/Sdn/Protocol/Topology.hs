{-# LANGUAGE TypeFamilies #-}

-- | Make up network layout

module Sdn.Protocol.Topology where

import           Control.Monad.Catch      (catchAll)
import           Control.TimeWarp.Logging (LoggerNameBox, usingLoggerName)
import           Control.TimeWarp.Rpc     (Method (..), MonadRpc, RpcRequest (..), serve)
import           Control.TimeWarp.Timed   (Microsecond, MonadTimed, after, for, fork_,
                                           interval, ms, sec, wait, work)
import           Data.Default             (Default (..))
import           Formatting               (build, sformat, shown, (%))
import           Test.QuickCheck          (arbitrary)
import           Universum

import           Sdn.Base
import           Sdn.Extra
import           Sdn.Protocol.Context
import           Sdn.Protocol.Messages
import           Sdn.Protocol.Phases
import           Sdn.Protocol.Processes

-- | Contains all info to build network which serves consensus algorithm.
data Topology = Topology
    { topologyMembers          :: Members
    , topologyProposalStrategy :: ProposalStrategy Policy
    , topologySeed             :: GenSeed
    , topologyBallotDuration   :: Microsecond
    , topologyLifetime         :: Microsecond
    }

-- | Example of topology.
instance Default Topology where
    def =
        Topology
        { topologyMembers = def
        , topologyProposalStrategy =
              generating (GoodPolicy <$> arbitrary)
        , topologySeed = RandomSeed
        , topologyBallotDuration = interval 3 sec
        , topologyLifetime = interval 2 sec
        }

-- | Create single newProcess.
newProcess
    :: (MonadIO m, MonadTimed m, Process p)
    => p
    -> LoggerNameBox (ReaderT (ProcessContext (ProcessState p)) m) ()
    -> ReaderT Members m ()
newProcess process action =
    fork_ $
    inProcessCtx process $
    usingLoggerName (processName process) $
    action

method
    :: ( MonadCatch m
       , MonadLog m
       , RpcRequest msg
       , Response msg ~ ()
       , Buildable msg
       )
    => (msg -> m ()) -> Method m
method endpoint = Method $ \msg -> do
    logInfo $ sformat ("Incoming message: "%build) msg
    endpoint msg `catchAll` handler
  where
    handler = logError . sformat shown

launchClassicPaxos
    :: (MonadIO m, MonadCatch m, MonadTimed m, MonadRpc m)
    => Topology -> m ()
launchClassicPaxos Topology{..} = flip runReaderT topologyMembers $ do

    newProcess Proposer . work (for topologyLifetime) $ do
        -- wait for servers to bootstrap
        wait (for 10 ms)
        let strategy = limited topologyLifetime topologyProposalStrategy
        execStrategy topologySeed strategy $ \policy ->
            submit (processAddress Leader) (ProposalMsg policy)

    newProcess Leader . work (for topologyLifetime) $ do
        work (for topologyLifetime) $ do
            -- wait for first proposal before start
            wait (for 20 ms)
            forever $ phrase1a >> wait (for topologyBallotDuration)

        serve (processPort Leader)
            [ method rememberProposal
            , method phase2a
            ]

    forM_ (processesOf Acceptor topologyMembers) $
        \process -> newProcess process . work (for topologyLifetime) $ do
            serve (processPort process)
                [ method phase1b
                , method phase2b
                ]

    forM_ (processesOf Learner topologyMembers) $
        \process -> newProcess process . work (for topologyLifetime) $ do
            serve (processPort process)
                [ method learn
                ]

    -- wait for everything to complete
    wait (after 100 ms topologyLifetime)
