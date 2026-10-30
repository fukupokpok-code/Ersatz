# Ersatz

Ersatz is a native macOS library for photos, RAW, video, and audio. Point it at folders on disk. It indexes them into a local catalog, shows a fast thumbnail grid, and opens stills, video, and sound in one window.

The catalog lives on this Mac. Files stay where they are.

## Requirements

- macOS 15 or later, Apple Silicon
- Xcode 27 or another toolchain with Swift 6 and the macOS SDK
- The app is a Swift package. It opens in Xcode or in VS Code with the Swift extension.
- ffmpeg is optional. Ersatz does not bundle or link it. Install it with `brew install ffmpeg` to play MKV, WebM, AVI, FLV, and WMV, and to read their codec, duration, and thumbnails.

`ErsatzCore` (indexing, SQLite, metadata, sorting) also builds on Linux so the unit tests can run without a Mac. The windowed app is macOS-only.

## Build and run on a Mac

Use Xcode’s toolchain so SwiftUI and the macOS SDK are available:

```bash
sudo xcode-select -s /Applications/Xcode.app
cd /path/to/Ersatz
swift test
./scripts/bundle.sh
open build/Ersatz.app
```

`scripts/bundle.sh` runs `swift build -c release` and wraps the binary in `build/Ersatz.app` (bundle id `com.mongkol.ersatz`), then ad-hoc signs it so Apple Silicon will launch it.

While developing, `swift run Ersatz` also starts the executable. The `.app` bundle is the one that behaves like a normal Mac application.

Add a folder from the toolbar or with File → Add Folder… (Command-O). Ersatz remembers the folder with a security-scoped bookmark and indexes it in the background.

## Tests on Linux or macOS

`ErsatzCore` uses the system SQLite library.

```bash
# Ubuntu / Debian
sudo apt install libsqlite3-dev
swift test
```

On a Mac, SQLite ships with the SDK; `swift test` is enough.

## Where data is stored

| What | Path |
| --- | --- |
| Catalog | `~/Library/Application Support/Ersatz/library.sqlite` |
| Thumbnails | `~/Library/Caches/Ersatz/Thumbnails` |
| Playback cache | `~/Library/Caches/Ersatz/Playback` |
| Checkpoints | `~/Library/Application Support/Ersatz/Checkpoints` |
| Activity log | `~/Library/Logs/Ersatz/activity.log` |

Removing a folder from the library does not delete the files.

## Using the window

The sidebar has four sections:

- **Library** — folders you added, with the directories inside them. The grid also shows each subfolder as a cover: one photo, or the first three fanned like a small stack. Folders with no photos keep a plain folder icon.
- **Date Taken** — year, then month. Capture dates are stored in the Gregorian calendar. An EXIF year above 2400 is treated as Buddhist Era and stored as year − 543, with a flag so you can write the corrected date back.
- **Type** — Photos, RAW, Video, Audio
- **Smart** — duplicates (SHA-256, plus a perceptual hash for near matches), blurry photos (Laplacian variance, adjustable threshold), screenshots, QR codes, Thai bank-transfer slips, and files whose dates were corrected from the Buddhist Era.

Sort by name, date taken, date modified, file size, resolution (pixel count), codec, or file type (kind, then format). Missing values sort last. Every thumbnail shows a resolution and format badge. The info panel is the only column to the right of the grid.

Indexing writes a basic catalog row first, so files show up before dimensions and EXIF are read. Metadata is extracted afterward with a small pool of tasks, one per processor. Analysis (hashes, sharpness, Vision on a Mac) runs as a later pass and is skipped when the file has not changed.

| Key | Action |
| --- | --- |
| Space | Toggle the full-size viewer |
| Esc | Leave the viewer |
| Left / Right | Previous / next item |
| Up / Down | Move through the grid or list |
| Return | Open the viewer |
| Command-O | Add a folder |
| Command-Delete | Remove the selected library folder |
| Command-I | Show or hide the info panel |
| Command-1 / Command-2 | Grid / list |
| Command-R | Reindex |
| Command-+ / Command-- | Larger or smaller thumbnails |
| Command-Shift-H | History |

In the viewer, drag pans a photo and the scroll wheel or trackpad pinch zooms it. Double-click toggles between fit and actual pixels. Video that AVFoundation can play uses the system player. MKV, WebM, AVI, FLV, and WMV go through ffmpeg on this Mac: Ersatz searches `/opt/homebrew/bin`, `/usr/local/bin`, and `PATH`, or a custom path in Settings. If ffmpeg is missing, the viewer explains `brew install ffmpeg` instead of failing quietly. H.264 or HEVC with AAC, Apple Lossless, MP3, AC-3, E-AC-3, or no audio is remuxed losslessly (`-c copy`, HEVC tagged `hvc1`, `-movflags +faststart`) into a cached MP4. Anything else is transcoded with VideoToolbox (`h264_videotoolbox` or `hevc_videotoolbox`) and AAC, with progress and cancel. The cache is keyed by path, size, and modification time and defaults to 5 GB. The original file is never modified. Audio has play, pause, and a scrubber. Arrow keys move between items instead of seeking.

Folders are watched with FSEvents. A change triggers an incremental reindex: files whose size and modification time are unchanged are skipped. New and edited files are read again, and files that disappeared are dropped from the catalog.

History → Fix Buddhist-Era Dates… lists files whose EXIF year was corrected. Nothing is written until you confirm. The original date is stored in a checkpoint (metadata only, not a second copy of the photo). ImageIO updates the file in place when it can; otherwise Ersatz writes an `.xmp` sidecar. Duplicate removal moves the files you do not keep to the Trash with `NSWorkspace.recycle` and records the Trash URL. Content edits, if added later, clone the original into the checkpoint folder with `FileManager.copyItem` (an APFS clone on Apple Silicon). Checkpoints older than 30 days are pruned, and the History window can cap how much backup storage they use. Every change is also appended to the activity log.

## Project layout

```
Package.swift
Sources/CSQLite/                  system SQLite module map
Sources/ErsatzCore/               catalog, parsers, indexer, sorting
Sources/Ersatz/                   SwiftUI app (macOS)
Tests/ErsatzCoreTests/            unit tests and generated sample files
Resources/Info.plist
scripts/bundle.sh
```

SQLite is linked from the system library (`libsqlite3`) instead of a third-party wrapper so `ErsatzCore` builds on Linux and macOS with the same code.

Metadata that can be read from file headers (JPEG EXIF, PNG, GIF, BMP, TIFF-based RAW, WAV, AIFF, FLAC, MP3, and MP4/QuickTime boxes) is parsed in `ErsatzCore`. On a Mac, ImageIO, AVFoundation, and Core Image fill gaps: ImageIO for stills and RAW metadata, Core Image (`CIRAWFilter`) when developing a RAW file for the viewer, AVFoundation for duration and codec, and QuickLook for video and audio thumbnails. For MKV, WebM, AVI, FLV, and WMV, indexing calls the user’s ffprobe (never a bundled binary) for resolution, codec, and duration, and thumbnails are one frame extracted with ffmpeg. If ffprobe is not installed, those files stay in the catalog as Video. Reindex after installing ffmpeg so the details fill in.

## What was verified here

On Linux, with Swift 6.3, `swift test` passes **44 tests**. That includes Buddhist-era date correction, file-type sorting, SHA-256, perceptual hashes, sharpness, screenshot and bank-slip heuristics, duplicate grouping, folder covers, checkpoints, the activity log, ffmpeg/ffprobe location, ffprobe JSON plans, remux and transcode arguments, progress parsing, and the playback-cache LRU. Those ffmpeg tests do not launch ffmpeg. Also included is a 40-file index benchmark. On these tiny JPEGs the measured times were sequential header reads **0.002s**, catalog insert **0.005s**, and the full two-pass index **0.007s**. The fixtures are too small for the worker pool to beat a straight parse; the catalog pass is what puts rows on screen before metadata, and the pool is sized to the processor count for ImageIO and AVFoundation work on a Mac.

`swift build` on Linux compiles the package. The `Ersatz` executable there only prints that the app requires macOS.

The SwiftUI target was not compiled or launched here. There is no macOS SDK in this environment. Build it on a Mac with the commands above. If the compiler reports errors, they can be fixed from that log.

## Known gaps

- The app is not sandboxed. Security-scoped bookmarks are still created and restored so a later sandbox would keep folder access.
- Symbolic links are not followed. Hidden files, AppleDouble `._` files, and bundle packages are skipped.
- If two library folders overlap, the index that ran last owns each path.
- The viewer decodes stills and RAW up to a pixel cap (about 3200 on the long edge when fitted, 8192 for actual size) so very large files are not fully expanded in memory.
- HEIC, CR3, and other formats the portable parser does not fully understand rely on ImageIO or AVFoundation on macOS. MKV, WebM, AVI, FLV, and WMV need a separate ffmpeg install. Without it they stay listed as Video, and the viewer shows how to install ffmpeg.
- A filesystem event rescans that folder incrementally. It does not patch a single file in isolation.
- Orphan thumbnail files are not purged when an item leaves the catalog.
- Capture dates are stored as Gregorian dates. The info panel still formats them with the Mac’s locale, so a Thai Buddhist calendar can display the corrected year in BE.
- QR codes and Thai slip text use Vision and are only collected on macOS. The keyword rules themselves are in ErsatzCore.
- No albums, ratings, or a general photo editor.
- The bundle is ad-hoc signed. There is no Developer ID signature.
- One window. Space toggles the viewer; use the on-screen controls to pause playback.

## License

MIT. See [LICENSE](LICENSE).

---

# Ersatz (ภาษาไทย)

Ersatz คือโปรแกรมบน macOS สำหรับจัดระเบียบรูปภาพ ไฟล์ RAW วิดีโอ และเสียง เลือกโฟลเดอร์บนดิสก์ แล้วโปรแกรมจะทำดัชนีไว้ในเครื่อง แสดงตารางภาพย่อ และเปิดภาพ วิดีโอ หรือเสียงในหน้าต่างเดียวกัน

ไฟล์ต้นฉบับไม่ถูกย้าย แคตตาล็อกอยู่บน Mac เครื่องนี้

## สิ่งที่ต้องมี

- macOS 15 ขึ้นไป บน Apple Silicon
- Xcode 27 หรือ toolchain อื่นที่มี Swift 6 และ macOS SDK
- โปรเจกต์เป็น Swift package เปิดได้ทั้งใน Xcode และ VS Code (ส่วนขยาย Swift)
- ffmpeg เป็นทางเลือก ไม่ได้รวมมากับแอปและไม่ได้ลิงก์เข้าไปในไบนารี ติดตั้งด้วย `brew install ffmpeg` เพื่อเล่นไฟล์ MKV, WebM, AVI, FLV, WMV และเพื่ออ่าน codec ความยาว และภาพย่อ

ไลบรารี `ErsatzCore` (ดัชนี, SQLite, metadata, การเรียงลำดับ) แปลบน Linux ได้ เพื่อรันเทสโดยไม่ต้องมี Mac ส่วนหน้าต่างแอปเป็นของ macOS เท่านั้น

## วิธี build และเปิดบน Mac

ให้ `swift` ชี้ไปที่ Xcode เพื่อให้มี SwiftUI และ macOS SDK:

```bash
sudo xcode-select -s /Applications/Xcode.app
cd /path/to/Ersatz
swift test
./scripts/bundle.sh
open build/Ersatz.app
```

`scripts/bundle.sh` รัน `swift build -c release` แล้วห่อไบนารีเป็น `build/Ersatz.app` (bundle id `com.mongkol.ersatz`) จากนั้นเซ็นแบบ ad-hoc เพื่อให้ Apple Silicon เปิดแอปได้

ระหว่างพัฒนา สั่ง `swift run Ersatz` ได้เช่นกัน แต่ไฟล์ `.app` คือวิธีเปิดแบบแอป Mac ปกติ

เพิ่มโฟลเดอร์จากแถบเครื่องมือ หรือเมนู File → Add Folder… (Command-O) โปรแกรมจำโฟลเดอร์ด้วย security-scoped bookmark แล้วทำดัชนีในพื้นหลัง

## เทสบน Linux หรือ macOS

`ErsatzCore` ใช้ SQLite ของระบบ

```bash
# Ubuntu / Debian
sudo apt install libsqlite3-dev
swift test
```

บน Mac มี SQLite มากับ SDK อยู่แล้ว ใช้ `swift test` ได้เลย

## ข้อมูลถูกเก็บที่ไหน

| สิ่งที่เก็บ | ที่อยู่ |
| --- | --- |
| แคตตาล็อก | `~/Library/Application Support/Ersatz/library.sqlite` |
| ภาพย่อ | `~/Library/Caches/Ersatz/Thumbnails` |
| แคชสำหรับเล่นวิดีโอ | `~/Library/Caches/Ersatz/Playback` |
| จุดตรวจ (checkpoint) | `~/Library/Application Support/Ersatz/Checkpoints` |
| บันทึกการทำงาน | `~/Library/Logs/Ersatz/activity.log` |

การเอาโฟลเดอร์ออกจากคลังไม่ลบไฟล์ต้นฉบับ

## วิธีใช้หน้าต่าง

แถบด้านข้างมีสี่ส่วน:

- **Library** — โฟลเดอร์ที่เพิ่ม และไดเรกทอรีภายใน ตารางภาพยังแสดงโฟลเดอร์ย่อยเป็นปก: รูปเดียว หรือสามรูปแรกวางซ้อนเอียงเล็กน้อย โฟลเดอร์ที่ไม่มีรูปใช้ไอคอนโฟลเดอร์ธรรมดา
- **Date Taken** — ปีแล้วเดือน วันที่ถ่ายถูกเก็บเป็นปฏิทินเกรกอเรียน ถ้าปีใน EXIF มากกว่า 2400 จะถือว่าเป็น พ.ศ. แล้วลบ 543 พร้อมจำไว้ว่าแก้แล้ว เพื่อเขียนวันที่ที่ถูกกลับลงไฟล์ได้
- **Type** — Photos, RAW, Video, Audio
- **Smart** — ไฟล์ซ้ำ (SHA-256 และ perceptual hash สำหรับรูปที่ใกล้เคียง), รูปเบลอ (ค่า Laplacian ปรับเกณฑ์ได้), ภาพหน้าจอ, คิวอาร์โค้ด, สลิปโอนเงินไทย, และไฟล์ที่วันที่ถูกแก้จาก พ.ศ.

เรียงตามชื่อ วันที่ถ่าย วันที่แก้ไข ขนาดไฟล์ ความละเอียด codec หรือชนิดไฟล์ (ประเภทแล้วตามฟอร์แมต) ค่าที่ไม่มีจะอยู่ท้ายสุด ภาพย่อทุกใบมีป้ายความละเอียดและฟอร์แมต แผงข้อมูลคือคอลัมน์เดียวทางขวาของตาราง

การทำดัชนีเขียนแถวพื้นฐานก่อน เพื่อให้ไฟล์โผล่ในตารางทันที แล้วค่อยอ่าน metadata พร้อมกันตามจำนวนตัวประมวลผล การวิเคราะห์ (แฮช ความคม และ Vision บน Mac) เป็นรอบถัดไป และข้ามไฟล์ที่ไม่เปลี่ยน

| ปุ่ม | การทำงาน |
| --- | --- |
| Space | เปิดหรือปิดมุมมองขนาดเต็ม |
| Esc | กลับจากมุมมองขนาดเต็ม |
| ลูกศรซ้าย / ขวา | รายการก่อนหน้า / ถัดไป |
| ลูกศรขึ้น / ลง | เลื่อนในตารางหรือรายการ |
| Return | เปิดมุมมองขนาดเต็ม |
| Command-O | เพิ่มโฟลเดอร์ |
| Command-Delete | เอาโฟลเดอร์ที่เลือกออกจากคลัง |
| Command-I | แสดงหรือซ่อนแผงข้อมูล |
| Command-1 / Command-2 | ตาราง / รายการ |
| Command-R | ทำดัชนีใหม่ |
| Command-+ / Command-- | ขยายหรือย่อภาพย่อ |
| Command-Shift-H | ประวัติ (History) |

ในมุมมองภาพ ลากเพื่อเลื่อนภาพ ใช้ล้อเมาส์หรือบีบนิ้วเพื่อซูม ดับเบิลคลิกสลับระหว่างพอดีหน้าต่างกับขนาดจริง วิดีโอที่ AVFoundation เล่นได้ใช้ตัวเล่นของระบบ ไฟล์ MKV, WebM, AVI, FLV และ WMV ส่งให้ ffmpeg ที่ติดตั้งบน Mac เครื่องนี้ Ersatz ค้นที่ `/opt/homebrew/bin` แล้ว `/usr/local/bin` แล้ว `PATH` หรือพาธที่ตั้งใน Settings ถ้าไม่พบ ffmpeg ตัวดูจะบอกวิธีติดตั้งด้วย `brew install ffmpeg` ไม่ได้เงียบหาย ถ้าภาพเป็น H.264 หรือ HEVC และเสียงเป็น AAC, Apple Lossless, MP3, AC-3, E-AC-3 หรือไม่มีเสียง จะ remux แบบไม่สูญเสีย (`-c copy`, HEVC ติดแท็ก `hvc1`, `-movflags +faststart`) เป็น MP4 ในแคช นอกนั้นจะแปลงด้วย VideoToolbox (`h264_videotoolbox` หรือ `hevc_videotoolbox`) และเสียงเป็น AAC พร้อมแถบความคืบหน้าและปุ่มยกเลิก แคชอ้างอิงจากพาธ ขนาด และเวลาแก้ไข ค่าเริ่มต้น 5 GB ไฟล์ต้นฉบับไม่ถูกแก้ เสียงมีปุ่มเล่น หยุดชั่วคราว และแถบเลื่อนเวลา ปุ่มลูกศรใช้เปลี่ยนรายการ ไม่ได้ใช้กรอวิดีโอ

โฟลเดอร์ถูกเฝ้าด้วย FSEvents เมื่อมีไฟล์เปลี่ยน โปรแกรมจะทำดัชนีแบบส่วนเพิ่ม: ไฟล์ที่ขนาดและเวลาแก้ไขเท่าเดิมจะถูกข้าม ไฟล์ใหม่หรือไฟล์ที่แก้จะถูกอ่านใหม่ และไฟล์ที่หายไปจะถูกเอาออกจากแคตตาล็อก

คำสั่ง Fix Buddhist-Era Dates… แสดงไฟล์ที่ปีถูกตีความเป็น พ.ศ. จะไม่เขียนไฟล์จนกว่าจะยืนยัน วันที่เดิมถูกเก็บใน checkpoint (เฉพาะ metadata ไม่ได้ก็อปปี้ไฟล์) ImageIO อัปเดตในไฟล์ได้เมื่อทำได้ ไม่งั้นจะเขียนไฟล์ `.xmp` คู่กัน การย้ายไฟล์ซ้ำไปถังขยะใช้ `NSWorkspace.recycle` และจำ URL ในถังขยะ ถ้าภายหลังมีการแก้เนื้อไฟล์ ต้นฉบับจะถูก clone ด้วย `FileManager.copyItem` (บน APFS เกือบไม่กินพื้นที่) checkpoint ที่เก่ากว่า 30 วันจะถูกลบ และหน้าต่าง History กำหนดเพดานพื้นที่สำรองได้ ทุกการเปลี่ยนถูกเขียนลง activity log ด้วย

## โครงสร้างโปรเจกต์

```
Package.swift
Sources/CSQLite/                  module map ของ SQLite ในระบบ
Sources/ErsatzCore/               แคตตาล็อก ตัวอ่าน metadata ดัชนี การเรียง
Sources/Ersatz/                   แอป SwiftUI (macOS)
Tests/ErsatzCoreTests/            เทสและไฟล์ตัวอย่างที่สร้างขึ้น
Resources/Info.plist
scripts/bundle.sh
```

SQLite ลิงก์จากไลบรารีของระบบ (`libsqlite3`) ไม่ได้ใช้ wrapper ของบุคคลที่สาม เพื่อให้ `ErsatzCore` แปลได้ทั้งบน Linux และ macOS ด้วยโค้ดชุดเดียวกัน

ข้อมูลที่อ่านจากส่วนหัวไฟล์ได้ (JPEG EXIF, PNG, GIF, BMP, RAW ที่เป็น TIFF, WAV, AIFF, FLAC, MP3 และกล่อง MP4/QuickTime) ถูกแยกใน `ErsatzCore` บน Mac, ImageIO, AVFoundation และ Core Image เติมส่วนที่ขาด: ImageIO สำหรับภาพนิ่งและ metadata ของ RAW, Core Image (`CIRAWFilter`) ตอนแสดงไฟล์ RAW, AVFoundation สำหรับความยาวและ codec, และ QuickLook สำหรับภาพย่อของวิดีโอและเสียง สำหรับ MKV, WebM, AVI, FLV และ WMV การทำดัชนีเรียก ffprobe ของผู้ใช้ (ไม่ได้ฝังไบนารี) เพื่ออ่านความละเอียด codec และความยาว และภาพย่อคือหนึ่งเฟรมจาก ffmpeg ถ้าไม่ได้ติดตั้ง ffprobe ไฟล์เหล่านี้ยังอยู่ในแคตตาล็อกเป็น Video หลังติดตั้งแล้วให้ทำดัชนีใหม่เพื่อเติมรายละเอียด

## สิ่งที่ตรวจแล้วในสภาพแวดล้อมนี้

บน Linux ด้วย Swift 6.3 คำสั่ง `swift test` ผ่าน **44 เทส** รวมการแก้ปี พ.ศ. การเรียงตามชนิดไฟล์ SHA-256 perceptual hash ความคม ฮิวริสติกภาพหน้าจอและสลิปธนาคาร การจัดกลุ่มไฟล์ซ้ำ ปกโฟลเดอร์ checkpoint บันทึก activity การหา ffmpeg/ffprobe แผนจาก JSON ของ ffprobe อาร์กิวเมนต์ remux/transcode ตัวอ่านความคืบหน้า และ LRU ของแคชสำหรับเล่นวิดีโอ เทสชุดนี้ไม่ได้รัน ffmpeg จริง รวมถึงเบนช์มาร์กดัชนี 40 ไฟล์ JPEG เล็ก ๆ เวลาที่วัดได้คือ อ่านส่วนหัวทีละไฟล์ **0.002 วินาที** ใส่แคตตาล็อก **0.005 วินาที** และดัชนีสองรอบทั้งก้อน **0.007 วินาที** ไฟล์ตัวอย่างเล็กเกินกว่าพูลเธรดจะเร็วกว่าการอ่านตรง ๆ จุดที่ได้จริงคือแถวโผล่ในตารางก่อน metadata และจำนวนงานเท่ากับจำนวนตัวประมวลผลสำหรับ ImageIO กับ AVFoundation บน Mac

`swift build` บน Linux แปลแพ็กเกจได้ ไบนารี `Ersatz` บนระบบนั้นจะบอกเพียงว่าแอปต้องใช้ macOS

ส่วน SwiftUI ยังไม่ได้แปลและยังไม่ได้เปิดบน Mac เพราะสภาพแวดล้อมนี้ไม่มี macOS SDK ให้ build บน Mac ตามคำสั่งด้านบน หากคอมไพเลอร์แจ้งข้อผิดพลาด ส่งบันทึกนั้นมาได้

## ข้อจำกัดที่รู้แล้ว

- แอปไม่ได้ใส่ sandbox แต่ยังสร้างและกู้ security-scoped bookmark ไว้ เพื่อให้เปิดโฟลเดอร์เดิมอีกครั้งได้
- ไม่ตาม symbolic link ข้ามไฟล์ที่ซ่อน ไฟล์ AppleDouble ที่ขึ้นต้นด้วย `._` และไม่เข้าไปใน bundle
- ถ้าสองโฟลเดอร์ในคลังซ้อนกัน รอบดัชนีล่าสุดจะเป็นเจ้าของพาธนั้น
- ตัวดูภาพถอดรหัสภาพนิ่งและ RAW ไม่เกินเพดานพิกเซล (ด้านยาวประมาณ 3200 เมื่อให้พอดีหน้าต่าง และ 8192 เมื่อขอดูขนาดจริง) เพื่อไม่ให้ไฟล์ใหญ่มากกินหน่วยความจำทั้งไฟล์
- HEIC, CR3 และฟอร์แมตที่ตัวอ่านแบบพกพายังอ่านไม่ครบ จะอาศัย ImageIO หรือ AVFoundation บน macOS ส่วน MKV, WebM, AVI, FLV และ WMV ต้องติดตั้ง ffmpeg แยก ถ้าไม่มี ไฟล์จะยังแสดงเป็น Video และตัวดูจะบอกวิธีติดตั้ง
- เมื่อไฟล์ในโฟลเดอร์เปลี่ยน จะสแกนโฟลเดอร์นั้นใหม่แบบส่วนเพิ่ม ไม่ได้แก้เฉพาะไฟล์เดียวแบบแยก
- ไฟล์ภาพย่อที่ค้างจะไม่ถูกลบเมื่อรายการออกจากแคตตาล็อก
- วันที่ถ่ายถูกเก็บเป็น ค.ศ. แผงข้อมูลยังจัดรูปแบบตามภาษาของเครื่อง ดังนั้นปฏิทิน พ.ศ. บน Mac ภาษาไทยจะแสดงปีที่แก้แล้วเป็น พ.ศ. ไม่ใช่ พ.ศ. ที่บวกซ้ำ
- คิวอาร์โค้ดและข้อความสลิปใช้ Vision และทำงานบน macOS เท่านั้น กฎคำสำคัญอยู่ใน ErsatzCore
- ยังไม่มีอัลบั้ม คะแนน หรือเครื่องมือแต่งรูปทั่วไป
- บันเดิลเซ็นแบบ ad-hoc ยังไม่มีลายเซ็น Developer ID
- มีหน้าต่างเดียว Space ใช้สลับมุมมองขนาดเต็ม การหยุดเล่นใช้ปุ่มบนหน้าจอ

## สัญญาอนุญาต

MIT ดูที่ [LICENSE](LICENSE)
