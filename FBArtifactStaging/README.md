# FBArtifactStaging

A macOS library that turns whatever a client sends to install — a local path, a URL, or an archive arriving on a stream — into a bundle on disk that a target can install.

The target frameworks only install what is already a bundle: `ApplicationCommands.install(atPath:)` takes an `.app`. Everything between the client's bytes and that path lives here, built on `FBControlCore`. `idb_companion` uses it for every install route, and it can be linked directly by other tools that install onto Simulators or Devices.

## What it provides

- **Installing from a source.** `ApplicationCommands.install(from:)` downloads, extracts and installs an application from an `InstallSource` in one call, reporting what happens as `InstallEvent`s: each stage's progress, how an archive was unpacked, and how a download went.
- **Staging.** `Staging.install` stages a source of any kind (application, test bundle, framework, dylib or dSYM), identifies the `Artifact` in it and hands that to the caller's install, removing whatever it unpacked afterwards.
- **Downloads.** URL sources are fetched with `URLSession` and extracted as they arrive (a zip is spooled to disk first, since its index is at the end), with progress and a `DownloadReport` of the transfer. A `ConnectionOverride` sends the connection to a given address instead of the one the URL's host resolves to, keeping the URL's host for TLS and HTTP.
- **Download cache.** With a `DownloadCache`, an application installed from a URL is kept extracted, keyed by the URL and the extract options, and a later install of the same URL clones it instead of downloading it (see [Download cache](#download-cache)). Without one, nothing is kept.
- **Archive extraction.** Tar (plain, gzip or zstd) and zip archives are extracted by sniffing the format from the first bytes rather than trusting what the client declared. Zip archives keep their file modes and symlinks, including when they arrive as a stream. Each format goes to whichever extractor is fastest for it (see [Routes](#routes)).
- **Extracting a payload.** `Staging.extract` extracts a stream of files that is not an artifact, such as a push, through the same extractors, errors and events as an install.
- **Archive creation.** `TarSource`, `GzippingSource` and `ArchiveOperations` write the archives the companion sends back to clients, such as pulled files and test results.

## How it fits together

Three layers, each depending only on the ones below it.

- **`Staging/`** is the entry point. `Staging.install` takes an `InstallSource` and an `ArtifactKind`, gets the source onto disk, identifies the `Artifact` in it, and calls the caller's install with it. Everything it unpacks lives in a temporary directory that is removed when the install returns, however it ends. It reports what happens as one ordered stream of `InstallEvent`s and fails with an `InstallError`.
- **`Downloads/`** fetches a `.remoteURL` and hands the bytes to extraction as they arrive, so the download and extract stages overlap. `DataDownloadInput` fetches it with `URLSession`. With a `ConnectionOverride`, `NetworkDownloadInput` fetches it instead: `URLSession` only connects to the address a host resolves to, so it opens a Network framework connection to the override's address, verifies TLS against the URL's host, and reads the HTTP/1.1 response itself (`HTTPResponseReader`). It asks for an identity encoding, accepts only a `200`, and does not follow redirects, since following one would leave the override behind. Both report the same events, errors and `DownloadReport`.
- **`Archives/`** holds the byte sources, the extractors and the archive writers. Its extractors know nothing about installs: they read a `ByteSource` or a file and write a tree.

### Byte sources

Every extractor reads a `ByteSource`, a blocking, pull-based reader. Extraction runs on its own thread, off Swift's cooperative pool, so a blocked read never starves other tasks. Bytes reach a source in one of three ways:

- **`FileDescriptorSource`** reads a file or a pipe, such as standard input.
- **`ChunkSource`** bridges an asynchronous producer, such as the frames of an RPC, to the extractor's synchronous reads. It holds at most `capacity` bytes (8 MiB by default) plus one chunk, and the producer's `pump` waits for room until half of it is free. That holds a fast client to the extractor's pace without waking the producer on every read. A producer that fails reaches the reader as `ChunkSource.UpstreamFailure`, never as a short archive. A reader that stops early calls `abandon`, and the producer then fails with `ChunkSource.ReaderClosed` instead of waiting for room that will not come.
- **`DownloadSpool`** carries a download. `URLSession` can't be held back: suspending a task does not stop what it has already read from arriving, and blocking its delegate queue starves the threads progress is reported on. So the download writes to an unlinked temporary file as fast as it arrives, and the reader follows behind on its own thread. A link faster than extraction puts what it is ahead by on disk rather than in memory.

### Routes

`SniffingExtractor` reads the first bytes of a stream and picks an extractor for them. Each choice is reported as an `ExtractionRoute`: the format, and what extracted it.

| Format | Stream | Download |
|---|---|---|
| zip, or a zip compressed with zstd | extracted as it arrives, while being spooled to disk; repaired from the spooled copy's central directory (modes, symlinks), or extracted again from it if the stream reader can't handle the zip (`zip_spool`) | the same |
| tar compressed with zstd | in-process tar extractor (`bsdtar` on macOS can't decompress zstd) | the same |
| tar compressed with gzip | `bsdtar` | in-process tar extractor |
| plain tar | in-process tar extractor | the same |

For each format, the default is whichever extractor measured fastest. A download is read back from its spool file, and the in-process extractors read that faster, and with less CPU, than `bsdtar` for every format. The client's declared compression is ignored. `ArchiveExtractors.default` and `ArchiveExtractors.inProcess` are the two configurations; `Benchmarks/` holds the benchmark that chooses between them.

Not every source is an archive. A directory is used where it is. A dylib or test run may arrive as the file itself, and a dylib may arrive gzipped. Any other file is taken to be an archive. Whatever is staged, if it doesn't hold an artifact of the kind being installed, fails as `unidentifiable`.

### Download cache

`Staging.install` takes an optional `DownloadCache`; `DownloadCache.fromEnvironment()` reads one from `IDB_INSTALL_CACHE_DIR`, bounded by `IDB_INSTALL_CACHE_MAX_BYTES` (20 GiB by default) and `IDB_INSTALL_CACHE_MIN_FREE_BYTES` (50 GiB by default). It applies to applications from a `.remoteURL` only.

- **Restore.** An entry is a directory holding what the archive extracted to, plus a file holding its identity (the URL and the extract options). The identity is compared on every restore, so entries whose names hash alike never mix. The entry is cloned into the staging directory with `clonefile(2)`, and the install proceeds from the clone as from an extraction, so whatever the install does to the bundle never reaches the cache. A hit reports the extract stage (the clone) and no download.
- **Store.** After a download extracts, the tree is cloned into a hidden directory in the cache and renamed into place, so other processes see a whole entry or none. When another process stored the same entry first, its copy is kept. Before storing, the least recently used entries are evicted until the new entry would leave at least the minimum free space on the cache's volume; when even an empty cache would not, the entry is not stored and the install reports `skipped_low_disk`. After storing, the least recently used entries, never the one just stored, are evicted until the cache fits its budget.
- **Failure.** The cache never fails an install: an entry that can't be cloned is a miss, and a store that fails is reported as `store_failed` and the install goes ahead. `clonefile(2)` needs the cache and the staging directory on the same APFS volume.
- **Freshness.** An entry lives no longer than its response said it may be reused, as RFC 9111 §4.2 reads it: it is kept only when the response gave an explicit lifetime (`Cache-Control: max-age`, or `Expires` against `Date`), less its `Age`, and never for `no-store` or `no-cache`. A restore past that time is a miss, and the download that follows replaces the entry, so a URL that starts serving another version is installed afresh once its old response expires. Each download's `DownloadReport.freshness` carries the lifetime, read from the response headers on both download paths.

Each install from a URL with a cache reports one `InstallEvent.cache` outcome: `hit`, `stored`, `store_failed`, `skipped_low_disk` or `not_cacheable`.

### Errors

Failures are classified by stage, so a caller can tell the user what went wrong without matching on messages:

- **`InstallError`** is what `Staging` throws. For a download, `httpStatus`, `transferFailed` (with the `DownloadReport` of the transfer) and `notAnHTTPResponse`. `extractionFailed` when the archive could not be extracted, `noInstallableBundle` when an extracted archive held no application, and `unidentifiable` when the staged source is not the kind it was installed as. When a download fails, it is reported as the transfer's failure, even though the extraction reading it fails too.
- **`ArchiveError`** is the underlying error from an extractor: `unsupported` (another extractor may read it), `corrupt`, `unsafePath` (an entry that would land outside the extraction root or pass through a symlink), and `extractorFailed` (`bsdtar` exited unsuccessfully, with the tail of its standard error). File system failures are `POSIXError`s.
- **`ChunkSource.UpstreamFailure` and `ChunkSource.ReaderClosed`** keep a failing producer from being mistaken for a damaged archive, and an early-finishing reader from being mistaken for a client failure. `idb_companion` reports the latter as an aborted RPC.

### Consumers

- **`idb_companion`** installs applications, test bundles, frameworks, dylibs and dSYMs through `Staging.install`, records `InstallEvent`s as install telemetry, and pushes files through `Staging.extract`. The contacts and media it is sent as tars in memory go through `TemporaryDirectory.withArchiveExtracted(_:)`.
- **`idb2`** installs through `ApplicationCommands.install(from:)`, from a path, a URL, or standard input.
- **`staging-bench`**, in `Benchmarks/`, measures the throughput, CPU and memory of every route.
