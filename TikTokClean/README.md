# TikTokClean

Minimal TikTok cleanup tweak for rootless jailbreaks.

Tested on **TikTok 45.7.0**.

## Features

- Hide UI button
- Clean video download through the iOS share sheet
- Auto-scroll when a video ends
- Always-visible progress bar
- Blocks TikTok-classified ads/live where possible
- Small version-based healthcheck for future TikTok updates

## Notes

- Tested only on TikTok 45.7.0.
- Official brand posts may still appear if TikTok does not classify them as ads.
- Photo posts are not handled as normal videos.
- Downloaded videos are shared as `.mp4` files through the iOS share sheet.
- The healthcheck log is written inside TikTok's app container as `log_tiktokclean.txt`.

To find the healthcheck log:

```sh
find /var/mobile/Containers/Data/Application -name log_tiktokclean.txt -print
```

Example healthcheck output:

TikTokClean health TikTok=45.7.0 OK

If TikTok changes something the tweak depends on, it may show something like:

TikTokClean health TikTok=46.0.0 MISSING class=AWEFeedCellViewController selector=playerWillLoopPlaying:

## Installation

Download the .deb from Releases and install it with Sileo, Zebra, Filza, or dpkg.

Example:

```sh
dpkg -i com.selandros.tiktokclean_1.0.0_iphoneos-arm64.deb
sbreload
```

## Compatibility

- Rootless jailbreaks
- TikTok 45.7.0
- Built for iphoneos-arm64

Other TikTok versions may work, but are not tested.

## Disclaimer

This tweak is provided as-is. Use it at your own risk.

## License

MIT
