{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}

-- | Various contexts of processes

module Sdn.Protocol.Context where

import           Control.Concurrent.STM (STM)
import           Control.Lens           (makeLenses)
import           Control.TimeWarp.Rpc   (MonadRpc, NetworkAddress, RpcRequest (..))
import           Control.TimeWarp.Timed (MonadTimed)
import           Data.Default           (Default (def))
import           System.Wlog            (NamedPureLogger, WithLogger, launchNamedPureLog)
import           Universum

import           Sdn.Base
import           Sdn.Extra

-- * General

-- | Context kept by single process.
data ProcessContext s = ProcessContext
    { pcState   :: TVar s   -- ^ Process'es mutable state
    , pcMembers :: Members  -- ^ Info about all participats of consensus
    }

-- | Constraint for having context with specified mutable state.
type HasContext s m =
    ( MonadIO m
    , MonadReader (ProcessContext s) m
    )

-- | Atomically modify state stored by process.
-- If exception is thrown in the process, no changes apply.
withProcessState
    :: (MonadIO m, WithLogger m, MonadReader (ProcessContext s) m)
    => StateT s (NamedPureLogger STM) a -> m a
withProcessState modifier = do
    var <- pcState <$> ask
    launchNamedPureLog (liftIO . atomically) $ do
        st <- lift $ readTVar var
        (res, st') <- runStateT modifier st
        lift $ writeTVar var st'
        return res

-- | Get 'Members' stored in context.
ctxMembers :: MonadReader (ProcessContext s) m => m Members
ctxMembers = pcMembers <$> ask

-- * Per-process contexts
-- ** Leader

-- * State kept by leader.
data LeaderState = LeaderState
    { _leaderBallotId        :: BallotId
      -- ^ Number of current ballot
    , _leaderPendingPolicies :: [Policy]
      -- ^ Proposed policies which were not replicated among acceptors yet
    , _leaderVotes           :: Map BallotId (Votes Configuration)
      -- ^ CStructs received in 2b messages.
    }

makeLenses ''LeaderState

-- | Initial state of the leader.
instance Default LeaderState where
    def = LeaderState def mempty mempty

-- ** Acceptor

-- * State kept by acceptor.
data AcceptorState = AcceptorState
    { _acceptorId       :: AcceptorId
      -- ^ Identificator of this acceptor, should be read-only
      -- TODO
    , _acceptorBallotId :: BallotId
      -- ^ Last heard ballotId from leader
    , _acceptorCStruct  :: Configuration
      -- ^ Gathered CStruct so far
    }

makeLenses ''AcceptorState

-- | Initial state of acceptor.
defAcceptorState :: AcceptorId -> AcceptorState
defAcceptorState id = AcceptorState id (BallotId (-1)) mempty

-- ** Learner

-- * State kept by learner.
data LearnerState = LearnerState
    { _learnerVotes   :: Votes Configuration
      -- ^ CStructs received from acceptors so far
    , _learnerLearned :: Configuration
      -- ^ Eventually learned cstruct, result of consensus
    }

makeLenses ''LearnerState

-- | Initial state of the learner.
instance Default LearnerState where
    def = LearnerState mempty mempty

-- * Misc

-- | Send a message to given participants.
broadcastTo
    :: ( MonadTimed m
       , MonadRpc m
       , MonadReader (ProcessContext s) m
       , RpcRequest msg
       , Response msg ~ ()
       )
    => (Members -> [NetworkAddress]) -> msg -> m ()
broadcastTo getAddresses msg = do
    members <- pcMembers <$> ask
    let addresses = getAddresses members
    forM_ addresses $ \addr -> submit addr msg