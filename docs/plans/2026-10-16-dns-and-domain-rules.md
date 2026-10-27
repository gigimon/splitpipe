# Description

Stage 4 of the original plan: per-app DNS and rules by domain and subnet. Not started.

# Implementation

## Step 1: Per-app DNS

[ ] `NEDNSProxyProvider` (a DNS flow carries the app's bundle id too). "Direct" apps resolve through the ISP's DNS, the
   rest through the VPN's DNS. Matters for geo-dependent CDNs.

## Step 2: Domain and subnet rules

[ ] Rules like "`*.ru`, banks → direct", including for the whole system. The DNS proxy remembers the IP → domain mapping,
   the transparent proxy routes by it.
[ ] Rule priority: domain > app > default.
