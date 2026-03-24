# WillFA7 v3.16 — Code-Analyse & Fehlerbehebung

## Kontext

WillFA7 emuliert Williams System 3/4/6/7 Flipper-MPUs auf Cyclone IV FPGA. Bei System3-Flippern funktionieren die Settings über NMI nicht. Zusätzlich werden alle gefundenen Schwachstellen behoben.

**Systemtyp-Erkennung:** `game_select` 0-8 = System3/4, ab 9 = System6/7.

---

## Implementierte Änderungen

### Fix 1: System3 PIA1 CA1/CB1 — automatische Umschaltung per game_select

**Datei:** `WillFA7.vhd`

**Problem:** CA1/CB1 waren fest auf System6/7-Logik (OR mit IRQ) verdrahtet. System3/4 braucht direkte Verbindung zu Advance/Up-Down für Settings per NMI.

**Änderungen:**
- Neues Signal `is_sys3` deklariert (Zeile 265)
- Ableitung aus `game_select`: `is_sys3 <= '1' when game_select <= "001000"` (Zeile 286)
- PIA1 CA1/CB1 bedingte Zuweisung (Zeilen 426-429):
  - System3/4: direkte Verbindung (`advance` / `up_down`)
  - System6/7: OR mit IRQ (bisheriges Verhalten)

```vhdl
pia1_ca1 <= advance when is_sys3 = '1'
            else not ( not advance or not cpu_irq);
pia1_cb1 <= up_down when is_sys3 = '1'
            else not ( not up_down or not cpu_irq);
```

**Hinweis:** `game_select` wird an SD-Card/EEPROM invertiert übergeben (`not game_select`, Zeile 361/392). Der Vergleich `<= "001000"` verwendet den direkten DIP-Wert. Bitte verifizieren, dass die DIP-Werte 0-8 tatsächlich den System3/4-Spielen entsprechen.

---

### Fix 2: Special Solenoid Reset aktivieren

**Datei:** `WillFA7.vhd`

**Problem:** `i_Rst_L => '1'` bei allen 6 `spec_sol_trigger`-Instanzen — Reset war nie aktiv, Solenoid-State-Machine konnte sich nicht zurücksetzen.

**Änderung:** Bei allen 6 SPECIAL-Instanzen (SPECIAL1-6):
```vhdl
-- Vorher:
i_Rst_L => '1', --RTH: gameon
-- Nachher:
i_Rst_L => reset_l,
```

`reset_l` statt `GameOn`, weil `reset_l` beim Boot low ist und dann high bleibt — sauberer Power-On-Reset. `GameOn` wäre auch möglich (setzt Solenoids bei Spielende zurück), aber `reset_l` ist sicherer da es den Boot-Zustand garantiert.

---

### Fix 3: Memory Protection für System3 deaktiviert

**Datei:** `WillFA7.vhd`

**Problem:** System3/4 hat kein Münztür-Schutzkonzept. Die Memory Protection konnte CMOS-Writes blockieren und damit Settings-Speicherung verhindern.

**Änderung:**
```vhdl
-- Vorher:
mem_prot_active <= mem_prot_ram_cs and mem_prot and opt_nvram_init_n;
-- Nachher:
mem_prot_active <= mem_prot_ram_cs and mem_prot and opt_nvram_init_n and not is_sys3;
```

---

## Nicht implementiert (dokumentierte TODOs)

### TODO: CPU68 DAA Flags

**Datei:** `cpu68.vhd`, Zeilen 62-64

Z-Flag wurde bereits korrigiert, aber Carry-Flag bei DAA könnte noch falsch sein. Betrifft BCD-Arithmetik (Punktestand). Erfordert separate Analyse des ALU-DAA-Case.

---

## Dokumentierte Schwachstellen (kein Fix nötig)

| # | Thema | Datei:Zeile | Schwere | Status |
|---|-------|-------------|---------|--------|
| A | PIA Adress-Dekodierung Überlappung | WillFA7.vhd:510-514 | Mittel | Bewusste Designentscheidung (Williams-kompatibel) |
| B | CMOS RAM (IC19) Clock 50MHz | WillFA7.vhd:926 | Niedrig | Nötig für Dual-Port EEPROM-Zugriff |
| C | Reset CDC (clk_50→cpu_clk) | WillFA7.vhd:412-413 | Niedrig | Unkritisch (einmalige Änderung) |
| D | Flipper-Solenoids ohne Pulslimit | WillFA7.vhd:454-455 | Niedrig | Williams-kompatibel (Relais-Steuerung) |
| E | RAM_S7 Clock | WillFA7.vhd:942 | — | Bereits korrekt (mem_clk) |

---

## Verifikation

1. **Quartus Kompilierung:** `quartus_sh --flow compile WillFA7`
2. **Timing-Analyse:** STA-Report prüfen auf neue Timing-Violations
3. **Hardware-Test System3:** Diagnostic-Taste (NMI) drücken → Settings ändern mit Advance/Up-Down → Settings speichern → Neustart → Settings prüfen ob gespeichert
4. **Hardware-Test System6/7:** Sicherstellen dass vorhandene Funktionalität nicht gebrochen ist
5. **Hardware-Test Solenoids:** Special Solenoids nach Reset-Fix testen
