//! Rootfs import/export as tar streams (plain / gzip / xz / zstd), pure Rust.

use crate::pb::ExportFormat;
use flate2::read::MultiGzDecoder;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;

/// Unpack a tar stream (compression auto-detected from magic bytes) into `dest`.
pub fn unpack(input: impl Read + Send + 'static, dest: &Path) -> Result<u64, String> {
    let mut br = BufReader::with_capacity(1 << 20, input);
    let magic = br.fill_buf().map_err(|e| format!("read: {e}"))?.to_vec();
    let reader: Box<dyn Read> = if magic.starts_with(&[0x1f, 0x8b]) {
        Box::new(MultiGzDecoder::new(br))
    } else if magic.starts_with(&[0xfd, b'7', b'z', b'X', b'Z', 0x00]) {
        // lzma-rs has no streaming Read adapter: decompress on a thread into a pipe.
        let (rd, mut wr) = std::io::pipe().map_err(|e| e.to_string())?;
        std::thread::spawn(move || {
            let mut br = br;
            if let Err(e) = lzma_rs::xz_decompress(&mut br, &mut wr) {
                crate::sys::log(&format!("xz: {e}"));
            }
        });
        Box::new(rd)
    } else if magic.starts_with(&[0x28, 0xb5, 0x2f, 0xfd]) {
        Box::new(ruzstd::decoding::StreamingDecoder::new(br).map_err(|e| format!("zstd: {e}"))?)
    } else {
        Box::new(br)
    };

    std::fs::create_dir_all(dest).map_err(|e| e.to_string())?;
    let mut ar = tar::Archive::new(reader);
    ar.set_preserve_permissions(true);
    ar.set_preserve_ownerships(true);
    ar.set_unpack_xattrs(true);
    ar.set_preserve_mtime(true);
    ar.set_overwrite(true);
    let mut n = 0u64;
    for entry in ar.entries().map_err(|e| format!("tar: {e}"))? {
        let mut entry = entry.map_err(|e| format!("tar: {e}"))?;
        // Device nodes come from devtmpfs at runtime.
        let t = entry.header().entry_type();
        if t.is_character_special() || t.is_block_special() {
            continue;
        }
        entry.unpack_in(dest).map_err(|e| format!("unpack {:?}: {e}", entry.path().ok()))?;
        n += 1;
    }
    Ok(n)
}

/// Write `root` as a tar stream in the given format.
pub fn pack(root: &Path, format: ExportFormat, out: impl Write + Send + 'static) -> Result<u64, String> {
    match format {
        ExportFormat::Tar => tar_to(root, out),
        ExportFormat::TarGz => {
            let mut gz = flate2::write::GzEncoder::new(out, flate2::Compression::default());
            let n = tar_to(root, &mut gz)?;
            gz.try_finish().map_err(|e| e.to_string())?;
            Ok(n)
        }
        ExportFormat::TarXz => {
            let (rd, wr) = std::io::pipe().map_err(|e| e.to_string())?;
            let mut out = out;
            let compressor = std::thread::spawn(move || {
                let mut br = BufReader::with_capacity(1 << 20, rd);
                lzma_rs::xz_compress(&mut br, &mut out).map_err(|e| format!("xz: {e}"))
            });
            let n = tar_to(root, wr)?; // dropping the writer ends the compressor's input
            compressor.join().map_err(|_| "xz thread panicked".to_string())??;
            Ok(n)
        }
    }
}

fn tar_to(root: &Path, out: impl Write) -> Result<u64, String> {
    let mut b = tar::Builder::new(out);
    b.follow_symlinks(false);
    b.mode(tar::HeaderMode::Complete);
    let mut n = 0u64;
    append_tree(&mut b, root, Path::new("."), &mut n)?;
    b.into_inner().map_err(|e| e.to_string())?.flush().map_err(|e| e.to_string())?;
    Ok(n)
}

/// Like `append_dir_all`, but skips sockets and device nodes instead of failing.
fn append_tree<W: Write>(b: &mut tar::Builder<W>, src: &Path, name: &Path, n: &mut u64) -> Result<(), String> {
    use std::os::unix::fs::FileTypeExt;
    let meta = std::fs::symlink_metadata(src).map_err(|e| format!("{}: {e}", src.display()))?;
    let ft = meta.file_type();
    if ft.is_socket() || ft.is_char_device() || ft.is_block_device() {
        return Ok(());
    }
    if ft.is_dir() {
        b.append_dir(name, src).map_err(|e| format!("{}: {e}", src.display()))?;
        *n += 1;
        let mut children: Vec<_> = std::fs::read_dir(src)
            .map_err(|e| format!("{}: {e}", src.display()))?
            .filter_map(Result::ok)
            .collect();
        children.sort_by_key(|e| e.file_name());
        for c in children {
            append_tree(b, &c.path(), &name.join(c.file_name()), n)?;
        }
    } else {
        b.append_path_with_name(src, name).map_err(|e| format!("{}: {e}", src.display()))?;
        *n += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_all_formats() {
        let tmp = std::env::temp_dir().join(format!("msl-archive-{}", std::process::id()));
        let src = tmp.join("src");
        std::fs::create_dir_all(src.join("etc")).unwrap();
        std::fs::write(src.join("etc/hostname"), "x\n").unwrap();
        std::os::unix::fs::symlink("hostname", src.join("etc/link")).unwrap();
        for (i, fmt) in [ExportFormat::Tar, ExportFormat::TarGz, ExportFormat::TarXz].into_iter().enumerate() {
            let file = tmp.join(format!("out{i}"));
            pack(&src, fmt, std::fs::File::create(&file).unwrap()).unwrap();
            let dst = tmp.join(format!("dst{i}"));
            let n = unpack(std::fs::File::open(&file).unwrap(), &dst).unwrap();
            assert_eq!(n, 4, "{fmt:?}");
            assert_eq!(std::fs::read_to_string(dst.join("etc/hostname")).unwrap(), "x\n");
            assert_eq!(std::fs::read_link(dst.join("etc/link")).unwrap(), Path::new("hostname"));
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
