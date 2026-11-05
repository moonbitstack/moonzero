///|
/// Read every regular file under `dir` into the set `@handler.Files` serves,
/// keyed by its path relative to `dir` with a leading slash. Subdirectories are
/// walked breadth-first, so a deep tree costs queue space rather than stack.
pub async fn load(dir : String) -> @handler.Files {
  let files = @handler.Files::new()
  let pending : Array[String] = [""]
  while pending.length() > 0 {
    let relative = pending.pop().unwrap()
    let absolute = if relative == "" { dir } else { dir + relative }
    let entries = @fs.readdir(absolute, include_hidden=false) catch { _ => [] }
    for name in entries {
      let child = relative + "/" + name
      let child_path = dir + child
      match @fs.kind(child_path) {
        Directory => pending.push(child)
        _ => {
          let body = @fs.read_file(child_path) catch { _ => continue }
          files.add(child, body.binary())
        }
      }
    }
  }
  files
}
