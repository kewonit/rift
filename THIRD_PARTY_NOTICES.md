# Third-party notices

Rift 0.3.0 uses these exact source dependencies and bundled data. macOS and
Xcode provide the Apple platform frameworks. This project does not redistribute
them as third-party packages.

## GRDB.swift 7.10.0

Revision: `36e30a6f1ef10e4194f6af0cff90888526f0c115`

Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Swift Argument Parser 1.8.2

Revision: `6a52f3251125d74daf04fcbd5e6f08a75d074382`

Copyright (c) Apple Inc. and the Swift project authors.

Licensed under the Apache License, Version 2.0, whose complete terms are in the
repository [LICENSE](LICENSE). Swift Argument Parser also includes this Runtime
Library Exception:

> As an exception, if you use this Software to compile your source code and
> portions of this Software are embedded into the binary product as a result,
> you may redistribute such product without providing attribution as would
> otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.

## Bundled network map data

`Scripts/build-network-data.sh` rebuilds the three files in
`Resources/NetworkData/` from the pinned sources below. Rift reads them only on
the Mac and makes no network requests for them.

### OpenStreetMap undersea cables

Cable data © OpenStreetMap contributors, from an Overpass snapshot dated
2026-10-25. OpenStreetMap data is available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/)
([copyright and license](https://www.openstreetmap.org/copyright)).
`network-map.json` is a derivative database that combines this cable geometry
with approximate main sea routes drawn by the build script, and it is made
available under the Open Database License 1.0. The Live Map credits
OpenStreetMap on screen.

### ip-location-db server-country

The IP-to-country table in `ip-country.bin` is derived from
[ip-location-db](https://github.com/sapics/ip-location-db) `server-country` at
commit `6953822901329539b856e9cf48aa95f2de579e87`, published under the
[Public Domain Dedication and License 1.0](https://opendatacommons.org/licenses/pddl/1-0/).
That dataset is compiled from Regional Internet Registry statistics, the Route
Views and RIPE RIS routing archives, and operator geofeeds.

### Natural Earth

Country label points and the land grid in `country-grid.bin` come from
[Natural Earth](https://www.naturalearthdata.com/) 1:50m admin-0 countries 5.1.1,
which is in the public domain.
