# Using Sikio

Phoenix LiveView, PostgreSQL and Ithibati passkeys with recovery codes and invitations. The
first visitor claims the instance; everybody after that arrives on an invitation link. There is
no administrator role and no mail delivery, so links are passed on by hand.

Under **Add**, the button below the wordmark or the plus on a phone, one field takes a link or a
search. An address with `://`, or a single word with a dot such as `radiolab.org`, is looked up;
anything else is searched for in Apple Podcasts. A guessed address that leads nowhere offers to
search for the same words. You can:

- Paste YouTube channel URLs, handles, video, Shorts and live URLs. Sikio resolves the channel
  behind them and shows its feed before you subscribe.
- Paste a PeerTube instance, channel, account or video URL. A video leads to its channel.
- Paste a podcast RSS feed or a podcast website. Several feeds found on one page are offered for
  choice, for example an MP3 and an Opus version of the same show.
- Search Apple Podcasts by a show's name, or paste an Apple Podcasts link. A preview checks the actual RSS feed
  before subscribing.

Subscribing imports the current episodes and opens the new source.

Under **Subscriptions**, the pencil beside the heading or **Manage** in the phone's library, you
can:

- Pause the polling of a subscription or resume it.
- Edit its name, where its new episodes go and its tags, as from the pencil on its own page.
- Leave it, after a question that names it.
- Import an OPML file with up to 50 unique sources and 1 MB, as a preview first. Existing
  subscriptions stay untouched and failures are reported per source. **Add** offers the import
  too. The export carries sources, not playback positions or polling settings. Format:
  [OPML 2.0](https://2005.opml.org/spec2.html).

New episodes arrive by polling. Oban refreshes active sources every 15 minutes, with
conditional HTTP requests and bounded retries. The library shows up to 100 matching items from
your sources, newest first. Filters by source, media type and status combine, and they live in
the URL, so a reload and the browser's back button keep them. New episodes, status changes and
subscriptions added or removed elsewhere appear without a reload.

Each source is stored once and shared; the subscriptions belong to individual accounts. A source
somebody paused can still be refreshed for other active subscribers. Removing a subscription
deletes no shared episodes.

**Play** opens the player for one item:

- Podcasts: native audio controls with pause, seek and speed from 0.75× to 2×. The player can be
  compacted without interrupting playback.
- YouTube: the official embed in privacy-enhanced mode, loaded only after a deliberate click.
- Your own state: new, in progress, or watched and heard. Marking is reversible, and marking
  something unwatched also resets its position.
- Positions are saved every five seconds, on pause, after seeking, and when the tab is hidden.
  Reaching the end completes the item; playing it again does not undo that.
- The visible player survives moving between the library, an item, the subscriptions and the
  invitations. One item plays per tab, and switching or closing waits for the last position to be
  saved. On a broken connection the switch waits until saving is possible again.
- A new player for the same item in another tab or on another device takes the session over. Old
  player messages and late events cannot overwrite a newer position. A lost connection pauses
  playback.

## Inviting somebody

`/invitations` makes a link and lists the ones nobody has accepted yet: for whom, by whom, when
it was made and when it runs out. A link is shown once, because only its digest is stored; pass
it on straight away or make a new one. When accounts are addressed rather than named, the link is
also sent to the address, and a delivery that fails is reported while the link stays shareable by
hand.

Take one back with "Take it back" and the link stops working at once. Any member may do that to
any invitation, the same rule as every member being able to make one. Nobody can be removed from
an instance once they are in, so this is the only moment anybody has a say over who joins. An
invitation older than this feature names nobody as its sender, and the list says so.

Progress survives feed updates and removing and re-adding a source. Marking by hand and removing
a subscription stop the affected player in other tabs immediately. A full reload, signing out or
closing the tab ends playback; pause briefly or close the player first so the last seconds are
saved.

Audio is loaded directly from the publisher, so available formats and seeking depend on the
browser and the media server. YouTube can refuse private, deleted or non-embeddable videos; the
player says so and links to YouTube. Only the embed and the API script send the page origin as a
referrer, because everything else is `no-referrer`.

URL discovery needs no personal API keys. Not every website publishes a discoverable feed; use
the direct RSS link then. Websites and feeds are capped at 8 MB, URLs at 2048 bytes, and website
discovery at five feed candidates. At most 500 episodes are taken per import. Supported are
podcast RSS with audio enclosures and YouTube Atom; general blog feeds are refused. The
application requests only public HTTP(S) addresses on ports 80 and 443, checks every redirect
target, and connects to the checked address while keeping the original TLS hostname.
