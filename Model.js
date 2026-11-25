.pragma library
// Pure helpers: lsblk parsing, size formatting, eject command lists.
var SAFE = /^\/dev\/[A-Za-z0-9\/_-]+$/

// One row per mounted filesystem (a btrfs device with many subvolume
// mounts is one row). `rem` is inherited from the parent disk.
function parse(text) {
  var rows = [], data
  try { data = JSON.parse(text) } catch (e) { return rows }
  function walk(n, top, rem) {
    if (!n || n.type === "loop") return
    rem = rem || n.rm === true || n.hotplug === true || n.tran === "usb"
    top = top || n
    var mps = (n.mountpoints || []).filter(function(m) { return typeof m === "string" && m[0] === "/" })
    var size = Number(n.fssize), avail = Number(n.fsavail)
    if (mps.length && n.fstype !== "swap" && n.fstype !== "squashfs" && size > 0 && isFinite(avail)) {
      mps.sort(function(a, b) { return a.length - b.length })
      rows.push({ name: String(n.label || mps[0]).substring(0, 60), path: String(n.path), mounts: mps,
                  avail: avail, size: size, removable: rem, disk: String(top.path),
                  uuid: n.fstype === "btrfs" && /^[0-9a-f-]{36}$/.test(n.uuid) ? n.uuid : "" })
    }
    var kids = n.children || []
    for (var i = 0; i < kids.length; i++) walk(kids[i], top, rem)
  }
  var devs = (data && data.blockdevices) || []
  for (var i = 0; i < devs.length; i++) walk(devs[i], null, false)
  rows.sort(function(a, b) { return a.mounts[0].length - b.mounts[0].length || (a.name < b.name ? -1 : 1) })
  return rows
}

// Binary units, one decimal under 10 (7.4G, 412G, 1.8T). nf(value, decimals) formats the number.
function size(b, nf) {
  var u = ["B", "K", "M", "G", "T", "P"], i = 0, v = b
  while (v >= 1024 && i < 5) { v /= 1024; i++ }
  return nf(v, (i > 0 && v < 9.95) ? 1 : 0) + u[i]
}

// Argv lists to eject a removable row's disk: unmount each of its mounted
// filesystems, then power the disk off. Returns null if any path is unsafe.
function ejectSteps(rows, disk) {
  var steps = [], ok = SAFE.test(disk)
  rows.forEach(function(r) {
    if (r.removable && r.disk === disk) { ok = ok && SAFE.test(r.path); steps.push(["udisksctl", "unmount", "-b", r.path]) }
  })
  if (!ok || steps.length === 0) return null
  steps.push(["udisksctl", "power-off", "-b", disk])
  return steps
}

// btrfs can freeze with free space left once every byte is reserved and the
// file-record area is nearly full. a = {mdUsed, mdTotal, disk} from sysfs.
// Returns 0 fine, 1 warning, 2 critical.
var GIB = 1073741824
function health(r, a) {
  if (!a) return 0
  var unalloc = r.size - a.disk
  if (unalloc < GIB && a.mdUsed / a.mdTotal >= 0.9) return 2
  return unalloc < Math.min(0.05 * r.size, 5 * GIB) ? 1 : 0
}
function freeLevel(r) { var f = r.avail / r.size; return f < 0.1 ? 2 : f < 0.2 ? 1 : 0 }

// Paths for one `tail -n +1` call over all btrfs uuids, and its parser.
function allocPaths(rows) {
  var out = [], seen = {}
  rows.forEach(function(r) {
    if (!r.uuid || seen[r.uuid]) return
    seen[r.uuid] = 1
    ;["metadata/bytes_used", "metadata/total_bytes", "data/disk_total", "metadata/disk_total", "system/disk_total"].forEach(function(k) {
      out.push("/sys/fs/btrfs/" + r.uuid + "/allocation/" + k)
    })
  })
  return out
}
function parseAlloc(text) {
  var f = {}, u = "", k = "", out = {}
  text.split("\n").forEach(function(l) {
    var h = /^==> \/sys\/fs\/btrfs\/([0-9a-f-]{36})\/allocation\/(\w+\/\w+) <==$/.exec(l)
    if (h) { u = h[1]; k = h[2]; f[u] = f[u] || {} } else if (k && /^[0-9]+$/.test(l)) f[u][k] = Number(l)
  })
  for (var id in f) {
    var x = f[id]
    out[id] = { mdUsed: x["metadata/bytes_used"], mdTotal: x["metadata/total_bytes"],
                disk: (x["data/disk_total"] || 0) + (x["metadata/disk_total"] || 0) + (x["system/disk_total"] || 0) }
  }
  return out
}
