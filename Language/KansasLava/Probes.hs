{-# LANGUAGE FlexibleInstances, FlexibleContexts, RankNTypes, ExistentialQuantification, ScopedTypeVariables, UndecidableInstances, TypeSynonymInstances, TypeFamilies, GADTs #-}
-- | Probes log the shallow-embedding signals of a Lava circuit in the
-- | deep embedding, so that the results can be observed post-mortem.
module Language.KansasLava.Probes (
 Probe(..), probe, probeCircuit, probeNames, probeValue, probeData,
 remProbes, mergeProbes, mergeProbesIO, exposeProbes, exposeProbesIO,
 toGraph, toTrace, fromTrace
 ) where

import qualified Data.Reify.Graph as DRG

import Data.List(nub,sortBy,sort,isPrefixOf)
import Control.Monad
import Control.Applicative
import qualified Data.Graph.Inductive as G

import qualified Data.Sized.Matrix as M

import Language.KansasLava.Comb
import Language.KansasLava.Fabric
import Language.KansasLava.Reify
import Language.KansasLava.Seq
import Language.KansasLava.Shallow
import qualified Language.KansasLava.Stream as S
import Language.KansasLava.Types

-- basic conversion to trace representation
toTrace :: forall w . (Rep w) => S.Stream (X w) -> TraceStream
toTrace stream = TraceStream (repType (Witness :: Witness w)) [toRep xVal | xVal <- S.toList stream ]

fromTrace :: (Rep w) => TraceStream -> S.Stream (X w)
fromTrace (TraceStream _ list) = S.fromList [fromRep val | val <- list]

-- this is the public facing method for probing
-- | Add a named probe to a circuit
probe :: (Probe a) => String -> a -> a
probe name = probe' [ OVar i name | i <- [0..] ]

-- | Probe all of the inputs/outputs for the given Fabric. The parameter 'n'
-- indicates the sequence length to capture.
probeCircuit :: Int -> Fabric () -> IO [(OVar, TraceStream)]
probeCircuit n fabric = do
    rc <- (reifyFabric >=> mergeProbesIO) fabric

    return [ (nm,TraceStream ty $ take n strm)
           | (_,Entity (TraceVal nms (TraceStream ty strm)) _ _) <- theCircuit rc
           , nm <- nms ]

-- | Get all of the named probes for a 'Circuit' node.
probeNames :: DRG.Unique -> Circuit -> [OVar]
probeNames n c = maybe [] fst $ probeData n c

-- | Get all of the prove values for a 'Circuit' node.
probeValue :: DRG.Unique -> Circuit -> Maybe TraceStream
probeValue n c = snd <$> probeData n c

-- | Capture the shallow embedding probe value to the deep embedding.
insertProbe :: OVar -> TraceStream -> Driver E -> Driver E
insertProbe n s@(TraceStream ty _) = mergeNested
    where mergeNested :: Driver E -> Driver E
          mergeNested (Port nm (E (Entity (TraceVal names strm) outs ins)))
                        = Port nm (E (Entity (TraceVal (n:names) strm) outs ins))
          mergeNested d = Port "o0" (E (Entity (TraceVal [n] s) [("o0",ty)] [("i0",ty,d)]))

-- | Get the probe names and trace from a 'Circuit' graph.
probeData :: DRG.Unique -> Circuit -> Maybe ([OVar], TraceStream)
probeData n circuit = case lookup n $ theCircuit circuit of
                        Just (Entity (TraceVal nms strm) _ _) -> Just (nms, strm)
                        _ -> Nothing

-- | The 'Probe' class is used for adding probes to all inputs/outputs of a Lava
-- circuit.
class Probe a where
    -- | Add probes (using the input list of 'OVar's as a name supply) to Lava
    -- circuit.
    probe' :: [OVar] -> a -> a

instance (Clock c, Rep a) => Probe (CSeq c a) where
    probe' (n:_) (Seq s (D d)) = Seq s (D (insertProbe n strm d))
        where strm = toTrace s
    probe' [] _ = error "Can't add probe: no name supply available (Seq)"

instance Rep a => Probe (Comb a) where
    probe' (n:_) (Comb s (D d)) = Comb s (D (insertProbe n strm d))
        where strm = toTrace $ S.fromList $ repeat s
    probe' [] _ = error "Can't add probe: no name supply available (Comb)"

instance (Probe a, Probe b) => Probe (a,b) where
    probe' names (x,y) = (probe' (addSuffixToOVars names "-fst") x,
                          probe' (addSuffixToOVars names "-snd") y)


instance (Probe a, Probe b, Probe c) => Probe (a,b,c) where
    probe' names (x,y,z) = (probe' (addSuffixToOVars names "-fst") x,
                            probe' (addSuffixToOVars names "-snd") y,
                            probe' (addSuffixToOVars names "-thd") z)

instance (Probe a, M.Size x) => Probe (M.Matrix x a) where
    probe' _ _ = error "Probe(probe') not defined for Matrix"

instance (Probe a, Probe b) => Probe (a -> b) where
    probe' (n:ns) f x = probe' ns $ f (probe' [n] x)
    probe' [] _ _ = error "Can't add probe: no name supply available (a -> b)"

addSuffixToOVars :: [OVar] -> String -> [OVar]
addSuffixToOVars pns suf = [ OVar i $ name ++ suf | OVar i name <- pns ]

-- | Convert a 'Circuit' to a fgl graph.
toGraph :: Circuit -> G.Gr (Entity DRG.Unique) ()
toGraph rc = G.mkGraph (theCircuit rc) [ (n1,n2,())
                                       | (n1,Entity _ _ ins) <- theCircuit rc
                                       , (_,_,Port _ n2) <- ins ]

-- Gives probes their node ids. This is used by mergeProbes and should not be exposed.
addProbeIds :: Circuit -> Circuit
addProbeIds circuit = circuit { theCircuit = newCircuit }
    where newCircuit = [ addId entity | entity <- theCircuit circuit ]
          addId (nid, Entity (TraceVal nms strm) outs ins) = (nid, Entity (TraceVal (map (addToName nid) nms) strm) outs ins)
          addId other = other
          addToName nid (OVar _ nm) = OVar nid nm


-- | Rewrites the circuit graph and commons up probes that have the same stream value.
mergeProbes :: Circuit -> Circuit
mergeProbes circuit = addProbeIds $ go (probeList circuit) circuit
    where go ((pid,Entity (TraceVal pnames strm) outs ins@[(_,_,d)]):pl) rc =
                         let others = probesOnAL d pl
                             otherIds = [ k | (k,_) <- others, k /= pid ]
                             newNames = nub $ pnames ++ concatMap snd others
                             updatedNames = updateAL pid (Entity (TraceVal newNames strm) outs ins) $ theCircuit rc
                         in go pl $ replaceWith (f pid) otherIds $ rc { theCircuit = updatedNames }
          go [] rc = rc
          go other _ = error $ "mergeProbes: " ++ show other
          f pid (Port s _) = Port s pid
          f _ p = p

-- | Lift the pure 'mergeProbes' function into the 'IO' monad.
mergeProbesIO :: Circuit -> IO Circuit
mergeProbesIO = return . mergeProbes

-- | Removes all probe nodes from the circuit.
remProbes :: Circuit -> Circuit
remProbes circuit = go (probeList circuit) circuit
    where go ((pid,Entity _ _ [(_,_,d)]):pl) rc =
                         let probes = pid : [ ident | (ident,_) <- probesOnAL d pl ]
                         in go pl $ replaceWith (\_ -> d) probes rc
          go [] rc = rc
          go other _ = error $ "remProbes: " ++ show other

-- | The 'exposeProbes' function lifted into the 'IO' monad.
exposeProbesIO :: [String] -> Circuit -> IO Circuit
exposeProbesIO names = return . (exposeProbes names)

-- | Takes a list of prefixes and exposes any probe whose name
-- contains that prefix as an output pad.
exposeProbes :: [String] -> Circuit -> Circuit
exposeProbes names rc = rc { theSinks = oldSinks ++ newSinks }
    where oldSinks = theSinks rc
          n = succ $ head $ sortBy (\x y -> compare y x) $ [ i | (OVar i _, _, _) <- oldSinks ]
          allProbes = sort [ (pname, nm, outs)
                        | (nm, Entity (TraceVal pnames _) outs _) <- theCircuit rc
                        , pname <- pnames ]
          exposed = nub [ (p, oty, Port onm nm)
                        | (p@(OVar _ pname), nm, outs) <- allProbes
                        , or [ name `isPrefixOf` pname | name <- names ]
                        , (onm,oty) <- outs ]
          showPNames x pname = show pname ++ "_" ++ show x

          newSinks = [ (OVar i $ showPNames i pname, ty, d) | (i,(pname, ty,d@(Port _ _))) <- zip [n..] exposed ]

-- Below is not exported.

-- Surely this exists somewhere!
updateAL :: (Eq k) => k -> v -> [(k,v)] -> [(k,v)]
updateAL key val list = [ (k,if k == key then val else v) | (k,v) <- list ]

replaceWith :: (Driver DRG.Unique -> Driver DRG.Unique) -> [DRG.Unique] -> Circuit -> Circuit
replaceWith _ [] rc = rc
replaceWith y xs rc = rc { theCircuit = newCircuit, theSinks = newSinks }
    where -- newCircuit :: [(DRG.Unique, Entity DRG.Unique)]
          newCircuit = [ (ident,Entity n o (map change ins))
                       | (ident,Entity n o ins) <- theCircuit rc
                       , ident `notElem` xs ]
          newSinks ::[(OVar, Type, Driver DRG.Unique)]
          newSinks = map change $ theSinks rc

          change :: (a, Type, Driver DRG.Unique) ->
                    (a, Type, Driver DRG.Unique)
          change (nm,ty,p@(Port _ i)) | i `elem` xs = (nm,ty,y p)
          change other = other

probeList :: Circuit -> [(DRG.Unique, Entity DRG.Unique)]
probeList rc = [ (n,e) | (n,e@(Entity (TraceVal _ _) _ _)) <- theCircuit rc ]

-- probesOn :: Driver DRG.Unique -> Circuit -> [(DRG.Unique,[ProbeName])]
-- probesOn x rc = probesOnAL x $ theCircuit rc

probesOnAL :: Driver DRG.Unique -> [(DRG.Unique, Entity DRG.Unique)] -> [(DRG.Unique,[OVar])]
probesOnAL x al = [ (ident,nms) | (ident, Entity (TraceVal nms _) _ ins) <- al
                             , (_,_,d) <- ins
                             , d == x ]
