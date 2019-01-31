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

Why is counter not public?
  - How to prevent neighbours figuring out your subscriptions?

Idea: multiple possible subscription prefixes that match a single message?
Related: maybe the subscription prefix comes with a nonce/random value that is used?

Idea: counter based on wall clock hour?
Idea: counter period configurable per channel? (Probably can't be changed after creation?)

Idea: time bots

Idea: channel rotation: new channel created; advertised in old.
  - new key
  - new feature set/configuration
  - new generator parameters
      - channel relays would need to be told about new params
  - to add/remove participants?
Problem: who does this? What makes them authorative? Race between multiple coordinators?

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
  - Channel Repeater: knows
  - Link: can be 1-1 or broadcast

Usually the first message is a subscription message.
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

Envelope contents:
  - counter
  - is-continuation (related to packetization)
  - in-reply-to
  - contents
      - should be an extensible format
          - cbor?
      - optional compression
          - selectable compression algorithms? (gzip vs xz vs ... )
              - what does this mean for client compatibility?
      - should support binary data (e.g. sharing emojis/"stickers"/images)
           - stickers: support reference to some other message that is the sticker?

