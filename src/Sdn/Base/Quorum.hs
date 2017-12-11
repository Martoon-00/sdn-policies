{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | Quorum-related stuff

module Sdn.Base.Quorum where

import           Control.Lens        (At (..), Index, IxValue, Ixed (..), Wrapped (..))
import           Data.List           (subsequences)
import qualified Data.Map            as M
import           Data.Reflection     (Reifies (..))
import qualified Data.Text.Buildable
import           Formatting          (bprint)
import           GHC.Exts            (IsList (..))
import           Test.QuickCheck     (Arbitrary (..), Gen, sublistOf, suchThat)
import           Universum           hiding (toList)
import qualified Universum           as U

import           Sdn.Base.Settings
import           Sdn.Base.Types
import           Sdn.Extra.Util

-- | For each acceptor - something proposed by him.
-- Phantom type @f@ stands for used quorum family, and decides whether given
-- number of votes forms quorum.
newtype Votes f a = Votes (M.Map AcceptorId a)
    deriving (Eq, Ord, Show, Monoid, Functor, Container, NontrivialContainer, Generic)

instance Wrapped (Votes t a)

instance IsList (Votes f a) where
    type Item (Votes f a) = (AcceptorId, a)
    toList (Votes v) = toList v
    fromList = Votes . fromList

type instance Index (Votes t a) = AcceptorId
type instance IxValue (Votes t a) = a

instance Ixed (Votes t a) where
    ix index = _Wrapped' . ix index

instance At (Votes t a) where
    at index = _Wrapped' . at index

instance Buildable a => Buildable (Votes t a) where
    build (Votes v) = bprint (buildList ", ") $ U.toList v

-- | All functions which work with 'Votes' can also be applied to
-- set of acceptors.
type AcceptorsSet f = Votes f ()

-- | Generates arbitrary votes using given value generator.
genVotes :: HasMembers => Gen a -> Gen (Votes f a)
genVotes genValue = do
    votes <- forM [1..acceptorsNum] $ \accId -> (AcceptorId accId, ) <$> genValue
    fmap fromList $ sublistOf votes
  where
    Members{..} = getMembers

instance (HasMembers, Arbitrary a) => Arbitrary (Votes f a) where
    arbitrary = genVotes arbitrary

-- | Sometimes we don't care about used quorum family.
data UnknownQuorum

-- | Remains votes for values which comply the predicate.
filterVotes :: (a -> Bool) -> Votes f a -> Votes f a
filterVotes p = listL %~ filter (p . snd)

-- | Describes quorum family.
class QuorumFamily f where
    -- | Check whether votes belong to a quorum of acceptors.
    isQuorum :: HasMembers => Votes f a -> Bool

-- | Check whether votes belogs to a minimum for inclusion quorum.
isMinQuorum :: (HasMembers, QuorumFamily f) => Votes f a -> Bool
isMinQuorum votes =
    let subVotes = votes & _Wrapped' . listL %~ drop 1
    in  isQuorum votes && not (isQuorum subVotes)

class QuorumIntersectionFamily f where
    -- | @isIntersectionWithQuorum v q@ returns whether exists quorum @r@
    -- such that @v@ is subset of intersection of @q@ and @r@.
    isIntersectionWithQuorum :: HasMembers => Votes f a -> Votes f b -> Bool

-- | Simple majority quorum.
data MajorityQuorum frac

instance Reifies frac Rational => QuorumFamily (MajorityQuorum frac) where
    isQuorum votes =
        let frac = reflect @frac Proxy
            Members{..} = getMembers
        in  fromIntegral (length votes) > fromIntegral acceptorsNum * frac

data OneHalf
instance Reifies OneHalf Rational where
    reflect _ = 1/2

data ThreeQuarters
instance Reifies ThreeQuarters Rational where
    reflect _ = 3/4

type ClassicMajorityQuorum = MajorityQuorum OneHalf
type FastMajorityQuorum = MajorityQuorum ThreeQuarters

-- | Take all possible minimum for inclusion quorums.
allMinQuorums
    :: (HasMembers, QuorumFamily f)
     => Votes f a -> [Votes f a]
allMinQuorums (Votes votes) =
    filter isMinQuorum $
    map (Votes . M.fromList) $ subsequences $ M.toList votes

-- | Add vote to votes.
addVote :: AcceptorId -> a -> Votes f a -> Votes f a
addVote aid a (Votes m) = Votes $ M.insert aid a m
