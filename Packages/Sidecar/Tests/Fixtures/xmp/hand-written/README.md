Hand-written sidecars for M-07, one per form the readers must handle (attribute, child element, `xap:` prefix,
several `rdf:Description` blocks, `<?xpacket?>` wrapper, reject, a custom label, a foreign namespace, and a
truncated file). Lightroom and RawTherapee fixtures arrive with M-25.

`lightroom-style-crs-3star-red.xmp` (M-25) is written by hand in the layout Lightroom Classic uses: `xpacket`
wrapper and padding, one `rdf:Description` with `xmp:Rating` and `xmp:Label` attributes, many `crs:` attributes,
and `crs:` child sequences (tone curve, masks) beside `xmpMM:History`. It is a stand-in. Replace it with a real
Lightroom sidecar when one is collected (G-10); the tests that use it need no other change.
