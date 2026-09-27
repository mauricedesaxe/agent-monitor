import json
from pathlib import Path


SCHEMA = {
    "schemaVersion": 1,
    "storeVersion": 4,
    "recordVersions": {
        "asset": {"version": 1, "subTypeKey": "type", "subTypeVersions": {"image": 2, "video": 2, "bookmark": 0}},
        "camera": {"version": 1},
        "document": {"version": 2},
        "instance": {"version": 17},
        "instance_page_state": {"version": 3},
        "page": {"version": 1},
        "shape": {"version": 3, "subTypeKey": "type", "subTypeVersions": {"group": 0, "embed": 4, "bookmark": 1, "image": 2, "text": 1, "draw": 1, "geo": 7, "line": 0, "note": 4, "frame": 0, "arrow": 1, "highlight": 0, "video": 1}},
        "instance_presence": {"version": 4},
        "pointer": {"version": 1},
    },
}

records = [
    {"id": "document:document", "typeName": "document", "gridSize": 10, "name": "", "meta": {}},
    {"id": "page:page1", "typeName": "page", "name": "Page 1", "index": "a1", "meta": {}},
]


def frame(name, x):
    ident = f"shape:{name}"
    records.append({
        "id": ident, "typeName": "shape", "type": "frame", "parentId": "page:page1",
        "index": "a1" if name == "live" else "a2", "x": x, "y": 50,
        "rotation": 0, "isLocked": False, "opacity": 1, "meta": {},
        "props": {"w": 760, "h": 650, "name": name.capitalize(), "color": "black"},
    })
    return ident


def box(ident, parent, index, x, y, w, h, label, color="black", fill="none", size="m"):
    records.append({
        "id": f"shape:{ident}", "typeName": "shape", "type": "geo", "parentId": parent,
        "index": index, "x": x, "y": y, "rotation": 0, "isLocked": False,
        "opacity": 1, "meta": {},
        "props": {
            "w": w, "h": h, "geo": "rectangle", "color": color, "labelColor": "black",
            "fill": fill, "dash": "draw", "size": size, "font": "draw", "text": label,
            "align": "middle", "verticalAlign": "middle", "growY": 0, "url": "",
        },
    })


live = frame("live", 50)
box("l_title", live, "a1", 35, 45, 420, 60, "Agent Monitor     LIVE", "blue", "semi", "l")
box("l_state", live, "a2", 570, 55, 150, 45, "● Sampling", "green", "semi")
box("l_ram", live, "a3", 35, 135, 325, 170, "RAM  3.8 GB\nAll harnesses", "blue", "semi", "l")
box("l_cpu", live, "a4", 390, 135, 330, 170, "CPU  28%\nOne core = 100%", "blue", "semi", "l")
box("l_graph", live, "a5", 35, 330, 685, 105, "Last 60 seconds   ▁▂▃▅▃▂▆▇▃▂", "grey", "none")
box("l_codex", live, "a6", 35, 460, 685, 48, "Codex                      2.7 GB RAM            26% CPU", "violet", "semi")
box("l_claude", live, "a7", 35, 518, 685, 48, "Claude Code             1.0 GB RAM              2% CPU", "grey", "semi")
box("l_open", live, "a8", 35, 576, 685, 48, "OpenCode                 Closed", "grey", "semi")

history = frame("history", 870)
box("h_title", history, "a1", 35, 45, 365, 60, "History     7 days", "blue", "semi", "l")
box("h_range", history, "a2", 425, 55, 295, 45, "24h    7d    30d", "grey", "none")
box("h_graph", history, "a3", 35, 135, 685, 210, "RAM over time    ▁▂▃▃▅▃▆▇▅▃▂▃▅▅▃", "blue", "none")
box("h_label", history, "a4", 35, 370, 685, 40, "Peak RAM during active minutes", "grey", "none")
for i, (name, value) in enumerate((("P50", "3.1 GB"), ("P90", "4.2 GB"), ("P95", "4.5 GB"), ("P99", "5.0 GB"))):
    box(f"h_p{i}", history, f"a{5+i}", 35 + i * 175, 430, 160, 125, f"{name}\n{value}", "violet", "semi", "l")
box("h_note", history, "a9", 35, 575, 685, 45, "Active minutes only   ·   Local SQLite history", "grey", "none")

target = Path(__file__).resolve().parent.parent / "design" / "wireframe.tldr"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({"tldrawFileFormatVersion": 1, "schema": SCHEMA, "records": records}, indent=2) + "\n")
