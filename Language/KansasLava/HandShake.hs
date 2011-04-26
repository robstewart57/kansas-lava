{-# LANGUAGE TypeFamilies, ExistentialQuantification, FlexibleInstances, UndecidableInstances, FlexibleContexts,
    ScopedTypeVariables, MultiParamTypeClasses, FunctionalDependencies,ParallelListComp,
    RankNTypes  #-}

module Language.KansasLava.HandShake where

import Control.Applicative
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString.Lazy as BS
import Data.Maybe as Maybe
import Data.Sized.Arith as Arith
import Data.Sized.Ix as X
import Data.Word

import Language.KansasLava.Comb
import Language.KansasLava.Shallow
import Language.KansasLava.Seq
import Language.KansasLava.Protocols
--import Language.KansasLava.Shallow.FIFO
import Language.KansasLava.Signal
import Language.KansasLava.Types
import Language.KansasLava.Utils

import System.IO

----------------------------------------------------------------------------------------------------

-- | Take a list of shallow values and create a stream which can be sent into
--   a FIFO, respecting the write-ready flag that comes out of the FIFO.
toHandShaken :: (Rep a, Clock c, sig ~ CSeq c)
             => [Maybe a]           -- ^ shallow values we want to send into the FIFO
             -> sig Bool
             -> sig (Enabled a)     -- ^ takes a flag back from FIFO that indicates successful write
                                    --   to a stream of values sent to FIFO
toHandShaken ys ready = toSeq (fn ys (fromSeq ready))
        where
--           fn xs cs | trace (show ("fn",take  5 cs,take 5 cs)) False = undefined
           fn (x:_) (Nothing:_) = x:(error "toHandShaken: bad protocol state (1)")
           fn (x:xs) (Just True:rs) = x:(fn xs rs)     -- has been written
           fn (x:xs) (_:rs) = x : fn (x:xs) rs -- not written yet
           fn [] _ = error "toHandShaken: can't handle empy list of values to issue"
           fn _ [] = error "toHandShaken: can't handle empty list of values to receive"


fromHandShaken' :: forall a c . (Clock c, Rep a) => HandShaken c (CSeq c (Enabled a)) -> [Maybe a]
fromHandShaken' (HandShaken sink) = res
    where (back, res) = fromHandShaken  (sink back)

-- | Take stream emanating from a FIFO and return a read-ready flag, which
--   is given back to the FIFO, and a shallow list of values.
fromHandShaken :: forall a c . (Clock c, Rep a)
               => CSeq c (Enabled a)       -- ^ fifo output sequence
               -> (CSeq c Bool, [Maybe a]) -- ^ read-ready flag sent back to FIFO and shallow list of values
fromHandShaken inp = (toSeq (map fst internal), map snd internal)
   where
        internal :: [(Bool,Maybe a)]
        internal = fn (fromSeq inp)

        fn :: [Maybe (Enabled a)] -> [(Bool,Maybe a)]
        fn ~(x:xs) = (True,rep) : rest
           where
                (rep,rest) = case x of
                               Nothing       -> error "fromVariableHandshake: bad reply to ready status"
                               Just Nothing  -> (Nothing,fn xs)
                               Just (Just v) -> (Just v,fn xs)

{-
fromHandshake' :: forall a . (Rep a) => [Int] -> Handshake a -> [Maybe a]
fromHandshake' stutter (Handshake sink) = map snd internal
   where
        val :: Seq (Enabled a)
        val = sink full

        full :: Seq Bool
        full = toSeq (map fst internal)

        internal :: [(Bool,Maybe a)]
        internal = fn stutter (fromSeq val)

        fn :: [Int] -> [Maybe (Enabled a)] -> [(Bool,Maybe a)]
        fn (0:ps) ~(x:xs) = (True,rep) : rest
           where
                (rep,rest) = case x of
                               Nothing       -> error "fromVariableHandshake: bad reply to ready status"
                               Just Nothing  -> (Nothing,fn (0:ps) xs)
                               Just (Just v) -> (Just v,fn ps xs)
        fn (p:ps) ~(x:xs) = (False,Nothing) : fn (pred p:ps) xs
-}

----------------------------------------------------------------------------------------------------

-- | This function takes a ShallowFIFO object, and gives back a Handshake.
-- ShallowFIFO is typically connected to a data generator or source, like a file.

shallowFifoToHandShaken :: (Clock c, Show a, Rep a) => MVar a -> IO (CSeq c Bool -> (CSeq c (Enabled a)))
shallowFifoToHandShaken sfifo = do
        xs <- getFIFOContents sfifo
        return (toHandShaken (xs ++ repeat Nothing))

handShakeToShallowFifo :: (Clock c, Show a, Rep a) => MVar a -> (CSeq c Bool -> CSeq c (Enabled a)) -> IO ()
handShakeToShallowFifo sfifo sink = do
        putFIFOContents sfifo
                $ Maybe.catMaybes
                $ (let (back,res) = fromHandShaken $ sink back in res)
        return ()

{- TODO: move into another location
-- create a lambda bridge from a FIFO to a FIFO.
-- (Could be generalize to Matrix of FIFO  to Matrix of FIFO)
handShakeLambdaBridge :: (Clock c) => (HandShaken c (CSeq c (Enabled Byte)) -> HandShaken c (CSeq c (Enabled Byte))) -> IO ()
handShakeLambdaBridge fn = bridge_service $ \ cmds [send] [recv] -> do
        sFIFO <- newShallowFIFO
        rFIFO <- newShallowFIFO

        forkIO $ hGetToFIFO send sFIFO
        hPutFromFIFO recv rFIFO

        sHS <- shallowFifoToHandShaken sFIFO
        let rHS = fn sHS
        handShakeToShallowFifo rFIFO rHS
        return ()
-}

incGroup :: (Rep x, Num x, Bounded x) => Comb x -> Comb x
incGroup x = mux2 (x .==. maxBound) (0,x + 1)

-- | Make a sequence obey the given reset signal, returning given value on a reset.
resetable :: forall a c. (Clock c, Rep a) => CSeq c Bool -> Comb a -> CSeq c a -> CSeq c a
resetable rst val x = mux2 rst (liftS0 val,x)

fifoFE :: forall c a counter ix .
         (Size counter
        , Size ix
        , counter ~ ADD ix X1
        , Rep a
        , Rep counter
        , Rep ix
        , Num counter
        , Num ix
        , Clock c
        )
      => Witness ix
         -- ^ depth of FIFO
      -> CSeq c Bool
         -- ^ hard reset option
      -> (CSeq c (Enabled a), CSeq c counter)
         -- ^ input, and Seq trigger of how much to decrement the counter
      -> (CSeq c Bool, CSeq c (Enabled (ix,a)), CSeq c counter)
         -- ^ backedge for input, and write request for memory, and internal counter.
fifoFE Witness rst (inp,dec_by) = (inp_ready,wr,in_counter1)
  where
--      mem :: Seq ix -> Seq a
--      mem = pipeToMemory env env wr

        inp_done0 :: CSeq c Bool
        inp_done0 = inp_ready `and2` isEnabled inp

        wr :: CSeq c (Enabled (ix,a))
        wr = packEnabled (inp_done0)
                         (pack (wr_addr,enabledVal inp))

        wr_addr :: CSeq c ix
        wr_addr = resetable rst 0
                $ register 0
                $ mux2 inp_done0 (liftS1 incGroup wr_addr,wr_addr)

        in_counter0 :: CSeq c counter
        in_counter0 = resetable rst 0
                    $ in_counter1
                        + mux2 inp_done0 (1,0)
                        - dec_by

        in_counter1 :: CSeq c counter
        in_counter1 = register 0 in_counter0

--      out :: Seq (Enabled a)
--      out = packEnabled (out_counter1 .>. 0) (mem rd_addr0)

        inp_ready :: CSeq c Bool
        inp_ready = (in_counter1 .<. fromIntegral (size (error "witness" :: ix)))
                        `and2`
                    (bitNot rst)

fifoBE :: forall a c counter ix .
         (Size counter
        , Size ix
        , counter ~ ADD ix X1
        , Rep a
        , Rep counter
        , Rep ix
        , Num counter
        , Num ix
        , Clock c
        )
      => Witness ix
      -> CSeq c Bool    -- ^ reset
--      -> (Comb Bool -> Comb counter -> Comb counter)
--      -> Seq (counter -> counter)
      -> (CSeq c counter,CSeq c (Enabled a))
        -- inc from FE
        -- input from Memory read
      -> CSeq c Bool
      -> ((CSeq c ix, CSeq c Bool, CSeq c counter), CSeq c (Enabled a))
        -- address for Memory read
        -- dec to FE
        -- internal counter, and
        -- output for HandShaken
fifoBE Witness rst (inc_by,mem_rd) out_ready =
    let
        rd_addr0 :: CSeq c ix
        rd_addr0 = resetable rst 0
                 $ mux2 out_done0 (liftS1 incGroup rd_addr1,rd_addr1)

        rd_addr1 = register 0
                 $ rd_addr0

        out_done0 :: CSeq c Bool
        out_done0 = out_ready `and2` (isEnabled out)

        out :: CSeq c (Enabled a)
        out = packEnabled ((out_counter1 .>. 0) `and2` bitNot rst `and2` isEnabled mem_rd) (enabledVal mem_rd)

        out_counter0 :: CSeq c counter
        out_counter0 = resetable rst 0
                     $ out_counter1
                        + inc_by
                        - mux2 out_done0 (1,0)

        out_counter1 = register 0 out_counter0
    in
        ((rd_addr0, out_done0,out_counter1) , out)

fifoCounter :: forall counter . (Num counter, Rep counter) => Seq Bool -> Seq Bool -> Seq Bool -> Seq counter
fifoCounter rst inc dec = counter1
    where
        counter0 :: Seq counter
        counter0 = resetable rst 0
                 $ counter1
                        + mux2 inc (1,0)
                        - mux2 dec (1,0)

        counter1 = register 0 counter0

fifoCounter' :: forall counter . (Num counter, Rep counter) => Seq Bool -> Seq counter -> Seq counter -> Seq counter
fifoCounter' rst inc dec = counter1
    where
        counter0 :: Seq counter
        counter0 = resetable rst 0
                 $ counter1
                        + inc -- mux2 inc (1,0)
                        - dec -- mux2 dec (1,0)

        counter1 = register 0 counter0

fifo :: forall a c counter ix .
         (Size counter
        , Size ix
        , counter ~ ADD ix X1
        , Rep a
        , Rep counter
        , Rep ix
        , Num counter
        , Num ix
        , Clock c
        )
      => Witness ix
      -> CSeq c Bool
      -> I (CSeq c (Enabled a)) (CSeq c Bool)
      -> O (CSeq c Bool) (CSeq c (Enabled a))
fifo w_ix rst (inp,out_ready) =
    let
        wr :: CSeq c (Maybe (ix, a))
        inp_ready :: CSeq c Bool
        (inp_ready, wr, _) = fifoFE w_ix rst (inp,dec_by)

        inp_done2 :: CSeq c Bool
        inp_done2 = resetable rst low $ register False $ resetable rst low $ register False $ resetable rst low $ isEnabled wr

        mem :: CSeq c ix -> CSeq c (Enabled a)
        mem = enabledS . pipeToMemory wr

        ((rd_addr0,out_done0,_),out) = fifoBE w_ix rst (inc_by,mem rd_addr0) out_ready

        dec_by = liftS1 (\ b -> mux2 b (1,0)) out_done0
        inc_by = liftS1 (\ b -> mux2 b (1,0)) inp_done2
    in
        (inp_ready, out)

fifoZ :: forall a c counter ix .
         (Size counter
        , Size ix
        , counter ~ ADD ix X1
        , Rep a
        , Rep counter
        , Rep ix
        , Num counter
        , Num ix
        , Clock c
        )
      => Witness ix
      -> CSeq c Bool
      -> I (CSeq c (Enabled a)) (CSeq c Bool)
      -> O (CSeq c Bool) (CSeq c (Enabled a),CSeq c counter)
fifoZ w_ix rst (inp,out_ready) =
    let
        wr :: CSeq c (Maybe (ix, a))
        inp_ready :: CSeq c Bool
        (inp_ready, wr, counter) = fifoFE w_ix rst (inp,dec_by)

        inp_done2 :: CSeq c Bool
        inp_done2 = resetable rst low $ register False $ resetable rst low $ register False $ resetable rst low $ isEnabled wr

        mem :: CSeq c ix -> CSeq c (Enabled a)
        mem = enabledS . pipeToMemory wr

        ((rd_addr0,out_done0,_),out) = fifoBE w_ix rst (inc_by,mem rd_addr0) out_ready

        dec_by = liftS1 (\ b -> mux2 b (1,0)) out_done0
        inc_by = liftS1 (\ b -> mux2 b (1,0)) inp_done2
    in
        (inp_ready, (out,counter))

{-
fifoToMatrix :: forall a counter counter2 ix iy iz c .
         (Size counter
        , Size ix
        , Size counter2, Rep counter2, Num counter2
        , counter ~ ADD ix X1
        , counter2 ~ ADD iy X1
        , Rep a
        , Rep counter
        , Rep ix
        , Num counter
        , Num ix
        , Size iy
        , Rep iy, StdLogic ix, StdLogic iy, StdLogic a,
        WIDTH ix ~ ADD (WIDTH iz) (WIDTH iy),
        StdLogic counter, StdLogic counter2,
        StdLogic iz, Size iz, Rep iz, Num iy
        , WIDTH counter ~ ADD (WIDTH iz) (WIDTH counter2)
        , Num iz
        , Clock c
        )
      => Witness ix
      -> Witness iy
      -> CSeq c Bool
      -> HandShaken c (CSeq c (Enabled a))
      -> HandShaken c (CSeq c (Enabled (M.Matrix iz a)))
fifoToMatrix w_ix@Witness w_iy@Witness rst hs = HandShaken $ \ out_ready ->
    let
        wr :: CSeq c (Maybe (ix, a))
        wr = fifoFE w_ix rst (hs,dec_by)

        inp_done2 :: CSeq c Bool
        inp_done2 = resetable rst low
                  $ register False
                  $ resetable rst low
                  $ register False
                  $ resetable rst low
                  $ isEnabled wr

        mem :: CSeq c (Enabled (M.Matrix iz a))
        mem = enabledS
                $ pack
                $ fmap (\ f -> f rd_addr0)
                $ fmap pipeToMemory
                $ splitWrite
                $ mapEnabled (mapPacked $ \ (a,d) -> (factor a,d))
                $ wr

        ((rd_addr0,out_done0),out) = fifoBE w_iy rst (inc_by,mem) <~~ out_ready

        dec_by = mulBy (Witness :: Witness iz) out_done0
        inc_by = divBy (Witness :: Witness iz) rst inp_done2
    in
        out

-- Move into a Commute module?
-- classical find the implementation problem.
splitWrite :: forall a a1 a2 d c . (Rep a1, Rep a2, Rep d, Size a1) => CSeq c (Pipe (a1,a2) d) -> M.Matrix a1 (CSeq c (Pipe a2 d))
splitWrite inp = M.forAll $ \ i -> let (g,v)   = unpackEnabled inp
                                       (a,d)   = unpack v
                                       (a1,a2) = unpack a
                                    in packEnabled (g .&&. (a1 .==. pureS i))
                                                   (pack (a2,d))

-}
mulBy :: forall x sz c . (Clock c, Size sz, Num sz, Num x, Rep x) => Witness sz -> CSeq c Bool -> CSeq c x
mulBy Witness trig = mux2 trig (pureS $ fromIntegral $ size (error "witness" :: sz),pureS 0)

divBy :: forall x sz c . (Clock c, Size sz, Num sz, Rep sz, Num x, Rep x) => Witness sz -> CSeq c Bool -> CSeq c Bool -> CSeq c x
divBy Witness rst trig = mux2 issue (1,0)
        where
                issue = trig .&&. (counter1 .==. (pureS $ fromIntegral (size (error "witness" :: sz) - 1)))

                counter0 :: CSeq c sz
                counter0 = cASE [ (rst,0)
                                , (trig,counter1 + 1)
                                ] counter1
                counter1 :: CSeq c sz
                counter1 = register 0
                         $ mux2 issue (0,counter0)
{-

-- sub-domain for the inner clock.
liftHandShaken :: (Clock c1)
        => (forall c0 . (Clock c0) => Clocked c0 a -> Clocked c0 b)
        -> HandShaken c1 (Enabled a)
        -> HandShaken c1 (Enabled b)
liftHandShaken f = undefined


-}

{-
-- Runs a program from stdin to stdout;
-- also an example of coding
-- interact :: (Src a -> Sink b) -> IO ()
-- interact :: (
-}

interactMVar :: forall a b
         . (Rep a, Show a, Rep b, Show b)
        => (forall clk sig . (Clock clk, sig ~ CSeq clk) => I (sig (Enabled a)) (sig Bool) -> O (sig Bool) (sig (Enabled b)))
        -> MVar a
        -> MVar b
        -> IO ()
interactMVar fn varA varB = do
        inp_fifo <- shallowFifoToHandShaken varA

        handShakeToShallowFifo varB $ \ rhs_back ->
                -- use fn at a specific (unit) clock
                let (lhs_back,rhs_out) = fn (lhs_inp,rhs_back :: CSeq () Bool)
                    lhs_inp = inp_fifo lhs_back
                in
                    rhs_out

hInteract :: (forall clk sig . (Clock clk, sig ~ CSeq clk) => I (sig (Enabled Word8)) (sig Bool) -> O (sig Bool) (sig (Enabled Word8)))
        -> Handle
        -> Handle
        -> IO ()
hInteract fn inp out = do
        inp_fifo_var <- newEmptyMVar
        out_fifo_var <- newEmptyMVar

        -- send the inp handle to the inp fifo
        _ <- forkIO $ forever $ do
                bs <- BS.hGetContents inp
                putFIFOContents inp_fifo_var $ BS.unpack bs

        -- send the out fifo to the out handle
        _ <- forkIO $ forever $ do
                x <- takeMVar out_fifo_var
                BS.hPutStr out $ BS.pack [x]

        interactMVar fn inp_fifo_var out_fifo_var

interact :: (forall clk sig . (Clock clk, sig ~ CSeq clk) => I (sig (Enabled Word8)) (sig Bool) -> O (sig Bool) (sig (Enabled Word8))) -> IO ()
interact fn = do
        hSetBinaryMode stdin True
        hSetBuffering stdin NoBuffering
        hSetBinaryMode stdout True
        hSetBuffering stdout NoBuffering
        hInteract fn stdin stdout
{-
liftToByteString :: (forall clk sig . (Clock clk, sig ~ CSeq clk)
          => I (sig (Enabled Word8)) (sig Bool) -> O (sig Bool) (sig (Enabled Word8)))
          -> IO (BS.ByteString -> BS.ByteString)
liftToByteString :
-
---------------------------------------------------------------------------------

-- The simplest version, with no internal FIFO.
liftCombIO :: forall a b c clk sig
        . (Rep a, Show a, Rep b, Show b)
       => (Comb a -> Comb b)
       -> (forall clk sig . (Clock clk, sig ~ CSeq clk) => I (sig (Enabled a)) (sig Bool) -> O (sig Bool) (sig (Enabled b)))
liftCombIO fn (lhs_in,rhs_back) = (lhs_back,rhs_out)
   where
           lhs_back = rhs_back
           rhs_out = mapEnabled fn lhs_in
 -}

-- Idea: FIFOs are arrows.
-- Problem: To implement Arrows, you need to make an instance of the Category
--          and Arrow classes. While composition, first, second, &&&, ***, are
--          fairly straightforward, id (from Category) and arr (from Arrow) are
--          too general (I think).
--
--          class Category cat where id :: cat a a ...
--          class Arrow a where arr :: (b -> c) -> a b c ...
--
--          We need to constrain id so a admits Rep. We also don't want to
--          admit an arbitrary function to arr. I think this is what we really
--          want:
--
--          class RepCategory cat where
--              id :: (Rep a) => cat a a
--              (.) :: (Rep a, Rep b, Rep c) => cat b c -> cat a b -> cat a c
--
--          class RepArrow a where
--              arr :: (Rep b, Rep c) => (Comb b -> Comb c) -> a b c
--              first :: (Rep b, Rep c, Rep d) => a b c -> a (b,d) (c,d)
--              -- note the following can be derived from arr, first, id, and (.)
--              -- but we might want to implement them by hand
--              second :: (Rep b, Rep c, Rep d) => a b c -> a (d,b) (d,c)
--              (***) :: (Rep b, Rep c, Rep b', Rep c') => a b c -> a b' c' -> a (b,b') (c,c')
--              (&&&) :: a b c -> a b c' -> a b (c,c')
--              -- note (>>>) = flip (.)
--
--          Rather than try for this class definition right way (there are a lot
--          more constraints than the Rep ones to manage) I started implementing
--          them outside the class as normal functions. So far, I have id, (.), and first
--          implemented. The others are coming soon.
--
-- Thought: What we really have here are circuit bits with an input type and output
--          type, and an algebra for gluing them together. With some work, combinatorial
--          and sequential circuits (absent fifos) would both fit into this paradigm
--          as well.
--
--          newtype CombCircuit a b = CC { runComb :: Comb a -> Comb b }
--          instance RepCategory CombA where
--              id = CC Prelude.id
--              (.) (CC g) (CC f) = CC (g Prelude.. f)
--
--          instance RepArrow CombA where
--              arr = CC
--              first (CC fn) = CC (\(b, d) -> (fn b, d))
--
--          etc...
newtype FIFO clk sz b c = FIFO { runFIFO :: I (CSeq clk (Enabled b)) (CSeq clk Bool)
                                         -> O (CSeq clk Bool) (CSeq clk (Enabled c)) }

idFifo :: forall clk sz a counter
       . ( Clock clk
         , Size sz
         , Num sz
         , Rep sz
         , Rep a
         , counter ~ ADD sz X1
         , Size counter
         , Num counter
         , Rep counter)
       => FIFO clk sz a a
idFifo = FIFO (fifo (Witness :: Witness sz) low)
-- TODO: Probably want to handle the reset signal for real.
-- TODO: Why do we need counter? fifoFE and fifoBE add X1 to sz,
--       but I don't understand why counter can't be equal to sz.

composeFifo :: ( Size gsz
               , Size fsz
               , combined ~ ADD gsz fsz
               , Size combined
               , fc ~ gb
               )
            => FIFO clk gsz gb gc
            -> FIFO clk fsz fb fc
            -> FIFO clk combined fb gc
composeFifo (FIFO g) (FIFO f) = FIFO (\(inp,rr) -> let (wr,o) = f (inp,wr')
                                                       (wr',out) = g (o,rr)
                                                   in (wr,out))

firstFifo :: forall clk sz b c d counter
          . ( Clock clk
            , Size sz
            , Rep b
            , Rep c
            , Rep d
            , Num sz
            , Rep sz
            , counter ~ ADD sz X1
            , Size counter
            , Num counter
            , Rep counter
            )
          => FIFO clk sz b c -> FIFO clk sz (b,d) (c,d)
firstFifo (FIFO f) = FIFO (\(inp,rr) -> let -- get the enabled signal off the tuple
                                            (en,tup) = unpack (inp :: CSeq clk (Enabled (b,d)))
                                            -- unpack the tuple
                                            (ifst,isnd) = unpack (tup :: CSeq clk (b,d))
                                            -- put the enabled signal back on each part
                                            (eif,eis) = (pack (en,ifst), pack (en,isnd))
                                            -- pass first part of tuple into fifo f
                                            (wrf,outf) = f (eif,rr)
                                            -- pass second part into the identity fifo
                                            (wrid,outid) = runFIFO (idFifo :: FIFO clk sz d d) (eis,rr)
                                            -- get the enabled signal off each output
                                            ((oen,osf),(oen',osid)) = (unpack outf, unpack outid)
                                            -- make a combined enabled output
                                            out = pack (oen .&&. oen', pack (osf,osid)) :: CSeq clk (Enabled (c,d))
                                        in (wrf .&&. wrid, out))
