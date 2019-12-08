---
title: "Plan9 br-abnt2 keyboard map"
date: 2019-05-09T21:00:00-03:00
tags: [
  "Plan9"
]
---

This is a quick post about a new Plan9 keyboard map, supporting the brazilian ABNT2 layout. 

<!--more-->

---

In order to use the new keyboard layout, just copy the following file (with a trailing newline!) to `/sys/lib/kbmap/br-abnt2`:

```bash
hget -o /sys/lib/kbmap/br-abnt2 https://gist.githubusercontent.com/mauri870/8ef952b83c44479262460e0330bfa1f1/raw/br-abnt2
```

Run [kbmap(1)](http://man.cat-v.org/plan_9/1/kbmap), the new layout should appear in the list. Since it's based on the ascii layout, select the ascii first to make sure that this layout loads on top of it.
 
<script src="https://gist.github.com/mauri870/8ef952b83c44479262460e0330bfa1f1.js"></script>

Also put `cat /sys/lib/kbmap/br-abnt2 > /dev/kbmap` into your `$home/lib/profile` under the `case 'terminal'` to apply the keyboard map at startup.

> NOTE: Unfortunatelly I could't figure out how to make the acentuation work, hence the 0 value in line 1, 4, 9 and 12.

If you have any thoughts in how to improve the configuration, let me know.
