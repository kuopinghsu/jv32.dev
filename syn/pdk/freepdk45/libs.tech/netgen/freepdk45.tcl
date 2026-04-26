# FreePDK45 / Nangate45 Netgen LVS setup
namespace path {::tcl::mathop ::tcl::mathfunc}

# ---------------------------------------------------------------------------
# Physical-only cells: filler, tap, and antenna cells have no logical
# function and are not present in the schematic netlist.  Ignore them so
# their fragmented VDD/VSS connections do not inflate the error count.
# Use catch{} for each cell so that variants not instantiated in this
# particular run (e.g. FILLCELL_X1 when only X2+ sizes are used) do not
# raise an error and abort the loop before the remaining cells are processed.
# ---------------------------------------------------------------------------
foreach _phys_cell {
    FILLCELL_X1 FILLCELL_X2 FILLCELL_X4 FILLCELL_X8 FILLCELL_X16 FILLCELL_X32
    TAPCELL_X1
    ANTENNA_X1
    PHY_EDGE_ROW_X1 PHY_EDGE_ROW_X2 PHY_EDGE_ROW_X4 PHY_EDGE_ROW_X8
} {
    catch {ignore class $_phys_cell}
}

# ---------------------------------------------------------------------------
# Permute symmetric cell pins so Netgen can match them without direction bias.
# ---------------------------------------------------------------------------
permute default
