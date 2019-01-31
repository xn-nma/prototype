Project Aims:
  - Can implement realtime-ish chat on top
  - Should work on high latency links
  - Low bandwidth links
  - Both high and low connectivity meshes
  - High and low density meshes (sometimes may just be a chain of single links)
  - 0 trust of neighbours required

Applications:
  - P2P chat on mobile devices at crowded events, e.g. festivals
       - eventually consistent with outside world/people not there
  - IRC/Matrix replacement

Stretch goal applications:
  - emergency communication (see: serval)
  - audio calls
  - video calls
  - IoT device communication
  - file sharing


Nodes have list of subscriptions

Subscriptions come from generators: channel id hashed with counter
Subscription packet contains aggregated subscription prefixes

Different links may set different lifetimes for subscriptions.
  - Want to avoid the need for "unsubscribe": only way to unsubscribe *now* is link-down
  - Should be some timeout based on medium?

What do you do if you get *too many* messages in reply to a subscription?
  - How do you know it's in reply to a subscription? (vs e.g. randomly generated messages)
  - How to know it's not spam data
  - Approach 1: keep first message received
  - Approach 2: keep last message received
  - Approach 3: keep or drop at random
  - Prefer local subscriptions over neighbour subscriptions?
      - Is this a potential side channel for a neighbour to figure out your local subscriptions?
  - Forward before drop?
      - "store-and-forward" vs "forward-and-store"
  - Subscribe to less in future?


What do you do if you get *very little* data in reply to a subscription
  - could be in isolated part of network
  - subscribe to more (larger prefixes? expand your local counter(s)?)

Channel has secret ID
  - On creation, pick random unsigned counter value to use?
  - ID is channel public key?

To send to a channel, you encrypt your message with the channel secret key and store it
If/When another nodes sends has a subscription that matches, you send it across the link

Concept of "channel relay": knows generator, but doesn't have ability to decrypt contents

"proof of relay": is it sufficient to just subscribe to a specific message (e.g. with random known-to-be-published counter) to check that a relay is doing what it promised?

Idea: when node sends new subscription packet:
  - own subscriptions (vary counter)
  - send *some* of neighbours subscriptions.
      - prefixes may be deaggregated
      - node should keep a record of link peer subscriptions and rotate through them

How to prevent all messages being stored forever? How to prevent traffic metadata to be extracted from a relay?

Resource constrained devices
  - Could be constrained in different ways. e.g. cpu vs network vs storage vs memory
  - Use more exact subscription prefixes.

Why is counter not public?
  - How to prevent neighbours figuring out your subscriptions?

Idea: multiple possible subscription prefixes that match a single message?
Related: maybe the subscription prefix comes with a nonce/random value that is used?

Idea: counter based on wall clock hour?
Idea: counter period configurable per channel? (Probably can't be changed after creation?)

Idea: time bots

Channel rotation: new channel created; advertised in old.
  - new key
  - new feature set/configuration
  - new generator parameters?
  - to add/remove participants?
  - resets counter
Problems:
  - who does the rotation? What makes them authorative? Race between multiple coordinators?
  - channel relays would need to be told about new params

Problem: freshly booted relay: neighbour does subscribe all. Channel history metadata (number of messages/sizes) leaked?
  - Is it a secure/privacy respecting solution to simply store some other messages too?

Fake message/traffic generation?

Hope: built in spam protection: only useful/subscribed messages get relayed for long
  - Propagation of messages decrease exponentially with each hop in a busy network?

Idea: Messages contain in-reply-to field?
  - Should be able to be in-reply-to multiple things
  - Nodes can then subscribe to any missing parent messages and recurse to get history

Idea: user channel: node always subscribes to private channel about self. Can be used to send invites?

Terminology:
  - Generator: a mathematical function that give a channel id and a counter, derives a possible message bucket
  - Channel:
  - Channel Repeater: knows generator, channel id: will repeat messages that match attempted counters
  - Link: can be 1-1 or broadcast

Usually the first message on a link is a subscription message.
  - Peers are free to ignore
Though published messages may be unasked for.
  - Emergency broadcast system?
  - Can always receive messages that you never subscribed to
      - Out of band subscriptions?

Message size guides (bytes):
  - SMS: 140
  - Zigbee: 100(?)
  - IPv4: 576
  - UDP over IPv4: 508
  - IPv6: 1280

Messages should have packetization.
  - Use in-reply-to

Protocol enclosure (this could be out of band. e.g. a http header; or xmpp enclosing type; etc)
  - Type (subscriptionlist/message)

Subscription List:
  - list of message id prefixes

Message:
  - Public:
      - message id
      - derived property: hash
  - Inside envelope:
      - counter
      - is-continuation (related to packetization)
      - in-reply-to
          - list of message ids + hash of entire message?
      - payload
          - should be an extensible format
              - cbor?
          - optional compression
              - selectable compression algorithms? (gzip vs xz vs ... )
                  - what does this mean for client compatibility?
          - should support binary data (e.g. sharing emojis/"stickers"/images)
               - stickers: support reference to some other message that is the sticker?

Storage model:
  - Message ids and matching by prefix would seem to fit a btree quite well.
