# Aefos AI — Additional Permissions

**Version 1.0**

Aefos AI is free software: you can redistribute it and/or modify it under the
terms of the **GNU General Public License, version 3**, as published by the Free
Software Foundation. The full text of that licence is in [`LICENSE`](LICENSE).

This file grants **additional permissions** under **section 7 of the GNU General
Public License version 3**. They *widen* what you may do; they never narrow it.
If anything in this file were ever read as restricting a right the GPL gives you,
the GPL wins and that reading is void.

In this document:

* **"Aefos"** and **"the Program"** mean the Aefos AI software — the RAD Studio
  Delphi plugin suite and its Lazarus/FPC edition — as distributed by the
  copyright holder under the GPL.
* **"You"** means a licensee of the Program.

---

## 1. Output Exception — the code Aefos writes for you is yours

**Grant.** Code, text, configuration, project files and other material that
Aefos generates, suggests, completes, scaffolds, refactors or inserts into your
own project (together, the **"Output"**) is **not** covered by the GNU General
Public License, and is **not** a derivative work of Aefos for the purposes of
this licence.

To the extent that any part of Aefos's own source code — templates, snippets,
boilerplate, scaffolding, generated headers or the like — is reproduced in the
Output, the copyright holder grants you an unlimited, irrevocable, worldwide,
royalty-free permission to use, copy, modify and distribute that part **under
any licence you choose**, including a proprietary one.

**What this means in practice.** Using Aefos to develop software places **no
licensing obligation whatsoever on that software**. You may build closed-source,
commercial, proprietary products with Aefos and distribute them under whatever
terms you like. You do not have to publish your source. You do not have to
mention Aefos. Aefos is a tool, and running a tool over your code does not
infect your code.

**Scope.** This exception is about the *Output*. It does not grant permission to
redistribute Aefos itself, or a modified Aefos, outside the GPL — that is
governed by section 2 below and by the GPL.

*(This clause follows the spirit of the GCC Runtime Library Exception: a
compiler that is free software must never make the programs it compiles
unfree.)*

---

## 2. Embarcadero and Platform Library Linking Exception

### 2.1 The problem this solves

Aefos is an **IDE plugin**. A RAD Studio design-time package (`.bpl`) cannot
exist at all without linking against Embarcadero's `designide` and the RAD
Studio runtime — those libraries are proprietary and are not GPL-compatible.
Without an explicit permission, the GPL's terms on combining with non-free
libraries would make it impossible to distribute a working Aefos build.

### 2.2 Grant

You have permission to **link or combine** Aefos, or any modified version of
Aefos, with:

* **Embarcadero RAD Studio runtime and design-time libraries** and their
  Delphi/C++Builder interface units — including but not limited to `rtl`,
  `vcl`, `vclx`, `vclie`, `vclimg`, `fmx`, `dbrtl`, `designide`, `ToolsAPI`,
  `FireDAC`, `IndyCore`/`IndyProtocols`, `soaprtl`, `xmlrtl`, the `dcl*`
  design-time packages, and any other library distributed by Embarcadero
  Technologies, Inc. as part of RAD Studio, Delphi or C++Builder;
* **Microsoft Edge WebView2** and the Microsoft Windows platform libraries and
  runtimes that Aefos calls or hosts;

and to **convey the resulting work**, including compiled design-time and
runtime packages (`.bpl`), executables and installers, under the terms of the
GNU General Public License version 3 — notwithstanding anything in that licence
to the contrary about combining GPL-covered work with libraries that are not
themselves under a GPL-compatible licence.

### 2.3 What this exception does *not* do

* It grants **no rights in Embarcadero's or Microsoft's software**. Those
  libraries remain licensed to you by their own vendors, under their own terms,
  and you must have a valid licence for them. This exception is a permission
  from the Aefos copyright holder only.
* It does **not** cover linking Aefos with arbitrary unrelated proprietary
  libraries. It is limited to the platform and IDE libraries listed above — the
  ones an IDE plugin cannot function without.
* The GPL still applies in full to Aefos's own source code. If you distribute a
  modified Aefos, you must still release your modifications under the GPL and
  provide the corresponding source.

---

## 3. These permissions are removable

As **GPLv3 section 7** expressly allows, you may **remove any or all of the
additional permissions in this file** from any copy of Aefos, or from any part
of it, that you convey — and you may require that they be removed from
downstream copies you receive with material you add.

Removing an additional permission has **no effect on the rest of the licence**:
the GNU General Public License version 3 continues to apply in full to the
Program either way. Removing a permission simply means the recipient of that
copy gets the plain GPL without that extra freedom.

If you remove a permission, the sensible thing is to say so plainly in your
distribution, so your users are not misled by a copy of this file that no longer
describes what they received.

---

## 4. No warranty

These additional permissions change nothing about warranty or liability.
Sections 15, 16 and 17 of the GNU General Public License version 3 apply to
Aefos in full: **the Program is provided without any warranty**, and Aefos is a
harness for autonomous AI tools that can change, move and delete code and run
commands — **you are responsible for reviewing every change it makes, keeping
backups, and validating any generated output before you rely on it.**

---

## 5. Notes

* **Third-party components** bundled with or vendored into Aefos keep their own
  licences. See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
* This document is not legal advice and its authors are not lawyers. If you need
  certainty for a commercial deployment, have your own counsel read it.

---

Copyright © 2026 Isaque de Souza Pinheiro.
