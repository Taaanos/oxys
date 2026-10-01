#!/bin/bash
# F-04: build TestData/xmp-kit/, the folders the manual interoperability checklist
# (docs/spikes/xmp-interop.md) opens in Lightroom Classic, RawTherapee and ART.
# Every RAW is an APFS clone of a file in TestData/ with a hand-written sidecar next to it.
# Each file name says what its sidecar holds, so a wrong reading is visible at a glance.
#   A-stem      sidecars named name.xmp       (Adobe style)
#   B-fullname  sidecars named name.ext.xmp   (darktable style)
#   C-forms     one Sony RAW, the same rating and label written four ways
#   D-labels    label strings: exact names, lowercase, custom text
#   E-date      two sidecar versions for the MetadataDate test (swap by hand, see the checklist)
# Safe to re-run: the kit is rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."
out=TestData/xmp-kit
src=TestData

# One RAW per vendor plus a DNG. There is no Nikon RAW in TestData/ yet (see the checklist).
sony="$src/DSC01014.ARW"
canon="$src/Canon - EOS R6 Mark III - RAW (3_2).CR3"
fuji="$src/Fujifilm - X-M1 - 12bit 12bit uncompressed (3_2).RAF"
dng="$src/DSC00204.dng"
for f in "$sony" "$canon" "$fuji" "$dng"; do [[ -f $f ]] || { echo "missing $f"; exit 1; }; done

rm -rf "$out"; mkdir -p "$out"/{A-stem,B-fullname,C-forms,D-labels,E-date}

# xmp <rating|-> <label|-> <date|->  → a complete sidecar on stdout. "-" leaves the property out.
xmp() {
  local attrs=""
  [[ $1 != - ]] && attrs+=" xmp:Rating=\"$1\""
  [[ $2 != - ]] && attrs+=" xmp:Label=\"$2\""
  [[ $3 != - ]] && attrs+=" xmp:MetadataDate=\"$3\""
  cat <<X
<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Oxys F-04 hand-written">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"$attrs/>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
X
}

# put <dir> <style stem|full> <source> <new stem> <rating> <label> <date>
put() {
  local dir=$1 style=$2 srcfile=$3 stem=$4 ext="${3##*.}"
  cp -c "$srcfile" "$out/$dir/$stem.$ext"
  local side="$out/$dir/$stem.xmp"; [[ $style == full ]] && side="$out/$dir/$stem.$ext.xmp"
  xmp "$5" "$6" "$7" > "$side"
}

d1=2026-10-01T09:00:00+02:00

# A: name.xmp
put A-stem stem "$sony"  sony-r3-red      3  Red   $d1
put A-stem stem "$canon" canon-r5-green   5  Green $d1
put A-stem stem "$fuji"  fuji-reject      -1 -     $d1
put A-stem stem "$dng"   dng-r2-blue      2  Blue  $d1

# B: name.ext.xmp
put B-fullname full "$sony"  sony-r4-yellow  4 Yellow $d1
put B-fullname full "$canon" canon-r1-purple 1 Purple $d1
put B-fullname full "$fuji"  fuji-r0-nolabel 0 -      $d1
put B-fullname full "$dng"   dng-reject      -1 -     $d1

# C: the same values (rating 4, Blue) as attribute, child elements, xap: prefix, and both mixed.
# Tools write all of these; M-07 must read them all. Naming style: name.xmp.
cp -c "$sony" "$out/C-forms/form-attr.ARW";  xmp 4 Blue $d1 > "$out/C-forms/form-attr.xmp"
for n in elem xap mixed; do cp -c "$sony" "$out/C-forms/form-$n.ARW"; done
cat > "$out/C-forms/form-elem.xmp" <<X
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
   <xmp:Rating>4</xmp:Rating>
   <xmp:Label>Blue</xmp:Label>
   <xmp:MetadataDate>$d1</xmp:MetadataDate>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
X
cat > "$out/C-forms/form-xap.xmp" <<X
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xap:Rating="4" xap:Label="Blue" xap:MetadataDate="$d1"/>
 </rdf:RDF>
</x:xmpmeta>
X
cat > "$out/C-forms/form-mixed.xmp" <<X
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4">
   <xmp:Label>Blue</xmp:Label>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
X

# D: label strings, all with rating 3.
i=0; for label in Red red RED Approved Review "Second" ""; do
  i=$((i+1)); name=$(printf 'label-%d-%s' $i "${label:-empty}" | tr ' ' '_')
  put D-labels stem "$sony" "$name" 3 "$label" $d1
done

# E: MetadataDate. Import with E-date/date-test.xmp = v1, then replace it by v2 (rating and date both change)
# and by v3 (rating changes, date does NOT), run "Read Metadata from Files" each time.
cp -c "$sony" "$out/E-date/date-test.ARW"
xmp 1 Red 2026-10-01T09:00:00+02:00 > "$out/E-date/date-test.v1.xmp"
xmp 4 Red 2026-10-01T10:00:00+02:00 > "$out/E-date/date-test.v2-newer-date.xmp"
xmp 5 Red 2026-10-01T09:00:00+02:00 > "$out/E-date/date-test.v3-same-date.xmp"
xmp 2 Red -                         > "$out/E-date/date-test.v4-no-date.xmp"
cp "$out/E-date/date-test.v1.xmp" "$out/E-date/date-test.xmp"

echo "kit at $out"; find "$out" -type f | sort | sed 's/^/  /'
