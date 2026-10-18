# Using Sikio

Sikio is a Phoenix LiveView application on SQLite or PostgreSQL. Ithibati provides passkeys,
recovery codes and invitations. The first account needs a setup code from the operator. Every
later account needs an invitation link. The account that claimed the instance is its
administrator. By default, accounts have usernames and invitation links are shared by hand. In
email mode, links are sent by mail. [Operations](operations.md) describes `ACCOUNT_IDENTITY` and
the mail settings.

**Add** is the button below the wordmark, or the plus button on a phone. Its input field
accepts a URL or a search term. Input with `://`, or a single word with a dot such as
`radiolab.org`, is treated as a URL. Other input searches Apple Podcasts, the Mediathek,
PeerTube and YouTube. If a guessed URL fails, the page offers a search for the same input. You can:

- Paste a YouTube channel URL, handle, video URL, Shorts URL or live URL. Sikio resolves the
  channel and shows a preview of its feed before you subscribe.
- Paste a PeerTube instance, channel, account or video URL. A video leads to its channel.
- Paste a podcast RSS feed or a podcast website. If a page links several feeds, you choose one,
  for example the MP3 or the Opus version of a show.
- Search Apple Podcasts by show name, or paste an Apple Podcasts URL. Sikio fetches and
  validates the show's RSS feed before it subscribes.
- Find films and programmes of the German public broadcasters. The same search asks
  [MediathekViewWeb](https://mediathekviewweb.de) for title and topic. A series is a
  programme's topic on its channel. Sikio plays the broadcaster's HD file in its own player.
  Versions with audio description, plain language or sign language and trailers are left out.
  A programme disappears when the broadcaster removes it from its media library. A saved or
  subscribed programme shows the picture its broadcaster's page names. A series, and a programme
  without such a picture, shows its broadcaster's icon where the broadcaster's site offers one.
  While the icon cannot be fetched, the video mark stands in. MediathekViewWeb lists some
  programmes twice, once blocked outside Germany, Austria and Switzerland. Sikio keeps one copy
  of each programme, the open one where there is one.
- Find PeerTube channels and videos without knowing their instance. The same search asks a
  PeerTube index, by default [Sepia Search](https://search.joinpeertube.org). The index covers
  the instances it has registered. Sensitive and live videos are left out. The operator can
  choose another index; see [Operations](operations.md).
- Find YouTube channels and videos by name. Sikio reads YouTube's results page and needs no API
  key. The request comes from the server, so YouTube sees the search term and the server's
  address, not your browser. Live and upcoming videos are left out. YouTube may answer with a
  consent page or a bot check, and the search then says so. Pasting a channel or video link still
  works.

A search asks Apple Podcasts, the Mediathek and PeerTube for up to 50 hits each and reads one
results page from YouTube. It shows all hits in one list, best match first. A title
that equals the search term ranks highest, then one that starts with it or contains it. A
misspelt term still finds a close title. A hit also ranks by the name of its podcast or channel,
a little below its own title. Each row names its index. The list appears once every index
answered, or after five seconds. A later answer joins the list.

Pills above the list name the kinds: **Podcasts**, **Episodes**, **Series**, **Programmes**,
**PeerTube channels**, **PeerTube videos**, **YouTube channels** and **YouTube videos**. Each
shows its count; a kind without hits shows no pill. Without a filter the list shows the best 20
hits. Pressing a pill shows every hit of its kind; pressing it again shows all kinds. Episodes
come from Apple Podcasts and are read from their podcast's feed. A row of an episode, a programme
or a video adds its item to the queue or the inbox, without a subscription. The same row
subscribes to its podcast, series or channel. A PeerTube video is read from its instance, a
YouTube video from YouTube, each as a pasted video link is. A long description shows two lines
until **more** is pressed. Rows of series and programmes show the picture of the broadcaster's
page once they come into view. Sikio fetches it and caches it, so the browser never contacts the
broadcaster.

**Subscribe** first asks two questions. **Episodes so far** takes only the newest, all of them
oldest first, or none. Episodes of one date are ordered by title. **New episodes go to** sets the
delivery target. The episodes taken go there too. The others are archived and stay in the source
under **All items**. The archive as target takes every episode, so the first question goes away.
A series from the search taken whole brings up to 100 programmes. Its refreshes ask for 20.
Subscribing then imports the current episodes and opens the new source. Subscribing again after
an unsubscribe decides afresh about episodes archived unplayed. Heard, started and queued
episodes keep their state.

A podcast whose feed carries no artwork takes its cover from Apple Podcasts, if Apple lists the
same feed. Its episodes show that cover when their own picture is missing, unreachable or
larger than 2 MB.

A link to one YouTube video, PeerTube video or podcast episode shows that item as a search
row. It adds the item to the queue or the inbox without a subscription, or subscribes to its
channel or podcast. A saved item stays when you unsubscribe from its source. **Remove from
library** in the item's menu deletes it. `/add?url=` followed by an encoded link fills in the
field and starts the lookup, for bookmarklets and share sheets.

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
- Move the library to another Sikio under **Move your library**. The export is one JSON file
  with sources, tags, queue, history, favourites, saved items and settings. It holds no
  passkeys, recovery codes or sessions. The import runs in the background and fetches every
  source again. It adds to the library and changes nothing already there. Settings apply only
  when none are stored. An episode no longer in its feed is looked up through its page when it
  was queued, started, starred or saved. Other such episodes are left out and counted. An
  import takes up to 5 MB, 500 sources and 20,000 episodes.

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
  play. Its own button enlarges it.
- **Fullscreen** beside the controls of a PeerTube or Mediathek video shows the video alone, with
  the browser's own controls. They can set speeds Sikio's button does not offer. Leaving
  fullscreen keeps position, speed and play state. An item that ends in fullscreen leaves it, and
  the queue plays on.
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

## Administration

The account that claimed the instance is its administrator. Administrators find every account
under **Settings → Accounts**, with its creation date and role. Members cannot open that page.
An administrator makes another account an administrator or revokes the role. The last
administrator keeps it. **Remove** deletes an account with its subscriptions, playback, tags and
passkeys, and ends its open sessions. Granting the role and removing an account first ask for
the passkey, unless it was confirmed in the last five minutes. A new administrator could remove
any account. Removing then asks for a confirmation. An administrator cannot remove their own
account there. Shared episodes and feeds stay. An administrator also finds **Remove for
everyone** in a source's edit dialog. The confirmation names how many members have some of it in
their library and how many items go. Its subscriptions, items and every account's progress,
favourites and saved items for it are deleted. Adding the feed again later starts afresh.

## Inviting somebody

`/invitations` creates invitation links and lists the pending ones. The list shows the invitee,
the inviter, the creation time and the expiry. A link expires after seven days and works once.
In email mode it is bound to the address it was created for. In username mode the invitee
chooses the username on accepting it. Each member may create 20 invitations per 24-hour window.
Only the token's digest is stored, so a link is shown once. Pass it on immediately or create a
new one. In email mode, the link is also mailed to the address. A failed delivery shows an
error, and the link can still be shared by hand.

"Take it back" deletes a pending invitation, and its link stops working immediately. A member
takes back the invitations they sent; an administrator takes back any. Invitations created
before the inviter was recorded show no inviter, and the list states that. An invitation from a
removed account names a former member.

Playback progress persists through feed updates and through unsubscribing and resubscribing.
Marking the playing item as heard or archived ends playback as if the item had ended. With
**Play on**, the queue continues. Removing a subscription stops its player in other tabs
immediately. A full reload, signing out or closing the tab ends playback. Pause briefly or close
the player first, so the last seconds are saved.

Audio loads directly from the publisher's server. PeerTube videos load from their instance.
Supported formats and seeking depend on the browser and that server. A PeerTube feed names no
stream. Sikio asks the instance's API for it each time a video plays, so a moved video still
plays. YouTube can refuse private, deleted or non-embeddable videos. The player then shows
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
