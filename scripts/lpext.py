import struct
f = open("/dev/nvme0n1p8", "rb")
f.seek(4096); g = f.read(4096)
magic, ssz, chk, mmax, slots, lbs = struct.unpack_from("<II32sIII", g, 0)
off = 4096*3
f.seek(off); h = f.read(512)
hmagic, maj, mnr, hsz = struct.unpack_from("<IHHI", h, 0)
p_off, p_num, p_sz = struct.unpack_from("<III", h, 80)
e_off, e_num, e_sz = struct.unpack_from("<III", h, 92)

f.seek(off + hsz + e_off)
extents = []
for i in range(e_num):
    e = f.read(e_sz)
    num_sectors, target_type, target_data, target_source = struct.unpack_from("<QIQI", e, 0)
    extents.append((num_sectors, target_type, target_data))

f.seek(off + hsz + p_off)
print("%-14s %14s %14s" % ("partition", "offset(bytes)", "size(bytes)"))
for i in range(p_num):
    e = f.read(p_sz)
    name = e[:36].split(b"\x00")[0].decode()
    attr, first_extent, num_extents, grp = struct.unpack_from("<IIII", e, 36)
    for j in range(first_extent, first_extent + num_extents):
        ns, tt, td = extents[j]
        print("%-14s %14d %14d" % (name, td*512, ns*512))
