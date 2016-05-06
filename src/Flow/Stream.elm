module Flow.Stream
  ( Factory
  , Pipe
  , Emitter

  , factory
  , flush
  , write
  , writeBatch
  , emit

  , stub
  , inlet
  , transform
  , capture
  , tap
  , combine
  ) where

{-| # Stream

This represents a source of deltas. Everything is lazily computed so if you don't reach read in
a given computation cycle, no work will be performed. In addition, no matter how many reads you
do, the result will only be computed once, because the underlying implementation is lazy by
memoization (see [maxsnew/lazy](https://github.com/maxsnew/lazy)).

# Types
@docs Factory, Pipe, Emitter

# Write
@docs factory, flush, write, writeBatch, emit

# Dataflow
@docs stub, inlet, transform, capture, tap, combine

-}

import Flow.Transform exposing (Transform)
import Flow.Sequence exposing (Counter)
import Flow.Internal.Stream as Internal


{-| A factory is used to write documents in to a source stream. -}
type alias Factory a =
  Internal.Factory a

{-| Pipes can be transformed and combined. Pipes are a transient representation of dataflow
configuration, and do not do any work themselves. -}
type alias Pipe a =
  Internal.Pipe a

{-| An emitter can be obtained from a Factory or a Pipe, and can be queried for the actual
resulting output of it's source object. Querying an emitter will result in the lazy evaluation of
all pipes that contribute to an emitter. -}
type alias Emitter a =
  Internal.Emitter a

--
-- SOURCE FACTORY
--

{-| A new source factory. This will start with a sequence number of 0. -}
factory : Factory a
factory = Internal.factory


{-| Flush a source factory. This will remove any writes, but keep the current write sequence
number. -}
flush : Factory a -> Factory a
flush = Internal.flush


{-| Write a reference document pair to a factory, increasing the sequence number monotonically. -}
write : String -> Maybe a -> (Counter, Factory a) -> (Counter, Factory a)
write = Internal.write


{-| Write a collection of reference document pairs to a factory, increasing the sequence number
monotonically for each. -}
writeBatch : List (String, Maybe a) -> (Counter, Factory a) -> (Counter, Factory a)
writeBatch = Internal.writeBatch


{-| Create an emitter from a factory. An emitter can be turned in to it's output, thus computing
it's final result lazily under the hood, or it can be `capture`d in to a pipe. This is useful if
you want to tap intermediate results. -}
emit : Factory a -> Emitter a
emit = Internal.emit


--
-- SOURCE PIPE
--


{-| Create a stub pipe with no documents. -}
stub : Pipe a
stub = Internal.stub


{-| Create a pipe directly from a factory. This is equivalent to:

    emit >> capture

-}
inlet : Factory a -> Pipe a
inlet = Internal.inlet


{-| Apply a transformation over the individual documents in the pipe. This transforms the type of
the pipe and may filter some documents out. -}
transform : Transform a b -> Pipe a -> Pipe b
transform = Internal.transform


{-| Capture an emitter as a pipe. -}
capture : Emitter a -> Pipe a
capture = Internal.capture


{-| Tap a pipe as an emitter to extract output. -}
tap : Pipe a -> Emitter a
tap = Internal.tap


{-| Combine a list of pipes producing an aggregate output. -}
combine : List (Pipe a) -> Pipe a
combine = Internal.combine
