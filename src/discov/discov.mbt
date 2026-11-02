// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Discovery over a file: one process writes what `moonsd/memory` holds, the others read it. For a
// deployment that hands out its instances as a file, as Prometheus's `file_sd` takes them, and for
// a program with no registry service to talk to.

///|
/// Write everything `registry` holds to `path`, replacing what was there.
pub async fn publish(path : String, registry : @memory.Registry) -> Unit {
  @fs.write_file(path, registry.snapshot(), create_mode=CreateOrTruncate)
}

///|
/// A `@moonsd.Discovery` over the file at `path`, and a file that is not there is no instances, so
/// a reader can start before the publisher has written anything. It reads the file on every
/// `resolve`, and a watcher wakes when the file's directory changes.
pub struct FileDiscovery {
  path : String
}

///|
pub fn FileDiscovery::new(path : String) -> FileDiscovery {
  { path, }
}

///|
async fn FileDiscovery::read(self : FileDiscovery) -> @memory.Registry {
  guard @fs.exists(self.path) else { return @memory.Registry::new() }
  @memory.Registry::restore(@fs.read_file(self.path).text())
}

///|
pub extend FileDiscovery with @moonsd.Discovery::{resolve, watch}

///|
pub impl @moonsd.Discovery for FileDiscovery with fn resolve(self, service) {
  self.read().resolve(service)
}

///|
/// A service followed through changes to the file.
priv struct FileWatcher {
  discovery : FileDiscovery
  service : String
  changes : @fs.Watcher
  mut last : Array[@moonsd.Endpoint]?
}

///|
impl @moonsd.Watcher for FileWatcher with fn next(self) {
  for ;; {
    let registry = self.discovery.read()
    let endpoints = registry.resolve(self.service)
    if self.last != Some(endpoints) {
      self.last = Some(endpoints)
      return { endpoints, revision: registry.revision(), }
    }
    ignore(self.changes.wait())
  }
}

///|
impl @moonsd.Watcher for FileWatcher with fn close(self) {
  self.changes.close()
}

///|
pub impl @moonsd.Discovery for FileDiscovery with fn watch(self, service) {
  let at = self.path.rev_find("/").unwrap_or(0)
  let directory = if at == 0 { "." } else { self.path[:at].to_owned() }
  let watcher : &@moonsd.Watcher = FileWatcher::{
    discovery: self,
    service,
    changes: @fs.Watcher(directory),
    last: None,
  }
  watcher
}
