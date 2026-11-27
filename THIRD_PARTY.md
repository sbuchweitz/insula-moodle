# Third-party code

## erseco/alpine-moodle (MIT)

The add-on plugin detection in `rootfs/usr/local/lib/insula-moodle/tree.sh` and several
cases in `tests/unit/test-tree.sh` are ported from
`rootfs/docker-entrypoint-init.d/010-sync-moodle-code.sh` and
`tests/unit/test-sync-moodle-code.sh` of https://github.com/erseco/alpine-moodle at
commit a2df5f648ef6999fb5a11b750fd1cdc77cbb0104.

```
MIT License

Copyright (c) 2023 Ernesto Serrano

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Moodle (GPL-3.0-or-later)

The images contain Moodle, downloaded from download.moodle.org at build time, and its
Composer dependencies. Moodle is Copyright (C) Martin Dougiamas and contributors.

## local_bbbrecordingsync (GPL-3.0-or-later)

`plugins/local/bbbrecordingsync` is a Moodle plugin, GPL-3.0-or-later like Moodle.
