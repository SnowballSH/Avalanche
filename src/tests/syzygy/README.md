# Syzygy test tables

The tables that `src/tests/syzygy.zig` probes, unchanged from
`https://tablebase.lichess.ovh/tables/standard/3-4-5-{wdl,dtz}/`, where their SHA-256 sums are
also published:

```
386fbde73308e49a4207836922c68b30b664e83c5a37f7fa37305a15cd16f2f1  KRvK.rtbw
cab59f42e75c2a25da3939231850a79fa838593fff5c28d7772da92062ed965a  KRvK.rtbz
517667dff787162dbb1ed9d5d6484d30ee854e686ee0675c08d99ecf045d2d50  KQvK.rtbw
71ea9444fa5bd42897d781a0c356975ea6f23e0f65a4254e470897031c161c8c  KQvK.rtbz
bc0d8ab3560de9038460f0e8f61e3b7efd3e3d0327d19ae0387c0da7ddeb244d  KBvK.rtbw
6246c8a5c643eec9d4758d55ed843e31cc28a9b82a6f630c1c950d8b7755975b  KBvK.rtbz
9d3518b12df3d2006441df758bce31e961346e70a11920aaad75c647003bb6e7  KNvK.rtbw
0e49a0f2810a131c32fc14872e83044aa9810ce2c86df071851512077291fc25  KNvK.rtbz
02fd2bdcd92821c869458f019f63524def1c9e7a2862ca8d2b16dc7712b16183  KPvK.rtbw
ad01af2076183c90ccee662ca6c5d74da3222ff1fee47c01b5d4e56ed01938de  KPvK.rtbz
797081b5b3fbac20c4baa5453d68bdae1425b63895f5c9a5ac5c68ea63a97712  KRvKR.rtbw
c23fa5a0209204b847232ed49e079c099cf603b43d6ace9e27257793b1839850  KRvKR.rtbz
```

Every capture and promotion from these positions leads to another of them, so a probe never needs a
table that is not here. KRvKR is the one that uses a DTZ value map; maps of 16-bit entries and the
flags of larger tables are not covered here.
