# mediaremote-adapter

Built from https://github.com/ungive/mediaremote-adapter at commit 3ac3d4b
(v0.7.6 line), BSD-3-Clause — see LICENSE. The framework is flattened
(no Versions/ symlinks) because it is only `dl_load_file`d by the script.

Rebuild:  cmake -S . -B build && cmake --build build
Copy:     build/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter,
          .../Resources/Info.plist, build/MediaRemoteAdapterTestClient,
          bin/mediaremote-adapter.pl
