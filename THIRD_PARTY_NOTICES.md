# Third-party notices

Rift 0.1.0 uses these exact source dependencies. macOS and Xcode provide the
Apple platform frameworks. This project does not redistribute them as
third-party packages.

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

## DB-IP City Lite (optional, user-provided data)

DB-IP City Lite is not bundled with Rift and is not downloaded automatically.
Users can obtain a current CSV snapshot from [DB-IP City Lite](https://db-ip.com/db/lite.php).
DB-IP provides the data under the [Creative Commons Attribution 4.0
International license](https://creativecommons.org/licenses/by/4.0/).

Required attribution: **IP Geolocation by DB-IP**.

When a user imports the CSV, Rift converts its ranges into a local SQLite index
for offline lookup. Rift does not intentionally change the source location
values. DB-IP data is approximate and may be stale or wrong.
