# Using Sikio

Sikio is a Phoenix LiveView application on SQLite or PostgreSQL. Ithibati provides passkeys,
recovery codes and invitations. The first account needs a setup code from the operator. Every
later account needs an invitation link. There is no administrator role. By default, accounts
have usernames and invitation links are shared by hand. In email mode, links are sent by mail.
[Operations](operations.md) describes `ACCOUNT_IDENTITY` and the mail settings.

**Add** is the button below the wordmark, or the plus button on a phone. Its input field
accepts a URL or a search term. Input with `://`, or a single word with a dot such as
`radiolab.org`, is treated as a URL. Other input is an Apple Podcasts search. If a guessed URL
fails, the page offers an Apple Podcasts search for the same input. You can:

- Paste a YouTube channel URL, handle, video URL, Shorts URL or live URL. Sikio resolves the
  channel and shows a preview of its feed before you subscribe.
- Paste a PeerTube instance, channel, account or video URL. A video leads to its channel.
- Paste a podcast RSS feed or a podcast website. If a page links several feeds, you choose one,
  for example the MP3 or the Opus version of a show.
- Search Apple Podcasts by show name, or paste an Apple Podcasts URL. Subscribing to a search
  result takes one click. Sikio fetches and validates the show's RSS feed first.

Subscribing imports the current episodes and opens the new source.

A link to one YouTube video, PeerTube video or podcast episode also offers **Only this item**.
That saves the item without a subscription, to the queue by default or to the inbox. A saved
item stays when you unsubscribe from its source. **Remove from library** in the item's menu
deletes it. `/add?url=` followed by an encoded link fills in the field and starts the lookup,
for bookmarklets and share sheets.

**Subscriptions** opens from the pencil beside its heading, or from **Manage** in the library on
a phone. There you can:

- Pause or resume polling for a subscription.
- Edit its name, its delivery target for new episodes and its tags. The pencil on the source
  page offers the same settings.
- Unsubscribe after a confirmation that names the source.
- Import an OPML file with up to 50 unique sources and up to 1 MB. A preview comes first.
  Existing subscriptions stay unchanged, and failures are listed per source. **Add** also links
  to the import. The export contains sources only, without playback positions or polling
  settings. Format: [OPML 2.0](https://2005.opml.org/spec2.html).

New episodes arrive by polling. Oban polls each active source at most once an hour by default.
Requests are conditional HTTP requests, and failed refreshes have bounded retries. The next poll
follows after a tenth of the newest episode's age, and at least once a day. The operator sets
the minimum interval with `FEED_POLL_MINUTES`, and the subscriptions page shows it. YouTube
channels can be **Live**: Google's hub then announces their new videos, and the subscriptions
page marks them. See [Operations](operations.md#youtube-channels-by-websub). Each
subscription sets the delivery target for new episodes: the inbox, the end of the queue, or the
archive as unheard.

The library has four places:

- **Inbox**: new items that are not queued.
- **Queue**: items to play, ordered by drag and drop or with the arrow keys. With **Play on**,
  the next item starts when one ends. **Play on** is on the settings page in the gear menu.
- **History**: heard items.
- **All items**: every item.

The library opens on the queue. The settings page in the gear menu can make the inbox or a tag
the start page instead.

The source and tag pages filter by new, heard or all. Lists load up to 100 items at a time. The
place and its search are part of the URL, so reloads and the browser's back button keep them.
New episodes, status changes and subscription changes from other tabs or devices appear without
a reload.

Sources are stored once and shared between accounts. Subscriptions belong to single accounts. A
source paused by one account is still refreshed for other active subscribers. Removing a
subscription deletes no shared episodes.

**Play** opens the player for one item:

- Podcasts: Sikio's own audio controls with play, pause, seek and speed from 0.75× to 2×. The
  player can be collapsed without interrupting playback.
- PeerTube: the instance's HLS stream in Sikio's own player, with the same controls as podcasts.
  Safari plays the stream itself. Other browsers play it through hls.js, up to 1080p.
  **Sound only** switches to the video's audio-only file, where the instance offers one. On iOS,
  only the sound keeps playing in the background. The player reports views to the instance, as
  PeerTube's own player does.
- YouTube: the official embed in its privacy-enhanced mode. The embed loads only after you press
  play.
- Playback status per account: new, in progress, heard or watched, or archived as unheard. An
  item counts as heard in its last minute. An item under ten minutes counts as heard at 90 % of
  its duration. Every mark can be undone. Marking an item unheard also resets its position.
- Positions are saved every five seconds, on pause, after seeking, and when the tab is hidden.
  Playing a heard item again keeps its heard status.
- The player keeps playing while you navigate between the library, an item, the subscriptions
  and the invitations. Each tab plays one item. Switching or closing an item first waits for the
  last position save. While the connection is down, the switch waits until saving works again.
- Opening the same item in another tab or on another device takes over the playback session.
  Stale player messages and late events cannot overwrite a newer position. A lost connection
  pauses playback.

## Inviting somebody

`/invitations` creates invitation links and lists the pending ones. The list shows the invitee,
the inviter, the creation time and the expiry. A link expires after seven days. It is bound to
the username or address it was created for and works once. Each member may create 20
invitations per 24-hour window. Only the token's digest is stored, so a link is shown once. Pass
it on immediately or create a new one. In email mode, the link is also mailed to the address. A
failed delivery shows an error, and the link can still be shared by hand.

"Take it back" deletes a pending invitation, and its link stops working immediately. Any member
may withdraw any invitation, as any member may create one. Sikio cannot remove an account.
Withdrawing an invitation is therefore the only control over who joins. Invitations created
before the inviter was recorded show no inviter, and the list states that.

Playback progress persists through feed updates and through unsubscribing and resubscribing.
Marking the playing item as heard or archived ends playback as if the item had ended. With
**Play on**, the queue continues. Removing a subscription stops its player in other tabs
immediately. A full reload, signing out or closing the tab ends playback. Pause briefly or close
the player first, so the last seconds are saved.

Audio loads directly from the publisher's server. PeerTube videos load from their instance.
Supported formats and seeking depend on the browser and that server. A PeerTube feed names no
stream. Sikio asks the instance's API for it when a video first plays. YouTube can refuse private, deleted or non-embeddable videos. The player then shows
a message and a link to YouTube. The referrer policy is `no-referrer`. Only the YouTube embed and
the YouTube IFrame API script send the page origin as referrer.

URL discovery needs no personal API keys. Not every website links a discoverable feed. Use the
direct RSS URL in that case. Limits:

- Websites and feeds: 8 MB.
- URLs: 2048 bytes.
- Website discovery: five feed candidates.
- Import: 500 episodes per feed.

Sikio supports podcast RSS with audio enclosures, YouTube Atom and PeerTube RSS. It
refuses general blog feeds. Outgoing requests go only to public HTTP(S) addresses on ports 80
and 443. Every redirect target is checked. The connection goes to the checked IP address and
keeps the original TLS hostname.
