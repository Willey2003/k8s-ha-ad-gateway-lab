#!/usr/bin/env python3
"""Generate the LAB lab infrastructure diagram as draw.io XML (editable, exportable to Visio) and SVG."""
import html, itertools
from xml.sax.saxutils import escape

# palette
C = dict(ink="#18222d", muted="#586674", rule="#9fb0bd",
         user="#eef3ff", userB="#5b7bd5", ad="#fff4e0", adB="#c98a1a",
         net="#f4f7f9", netB="#7f95a6", cp="#e3f1f2", cpB="#0d6b76",
         wk="#eef6ec", wkB="#3f8a4a", etcd="#fbeaea", etcdB="#b04848",
         bas="#f1ecfb", basB="#6d52b8", gw="#e6f3fb", gwB="#1f78b4", vip="#0d6b76", router="#fff8d6", routerB="#a08a1c")

nodes, edges = [], []
def box(id, x, y, w, h, title, sub="", fill="#fff", stroke="#999", kind="node", bold=True, fs=13):
    nodes.append(dict(id=id, x=x, y=y, w=w, h=h, title=title, sub=sub, fill=fill, stroke=stroke, kind=kind, bold=bold, fs=fs))
def edge(a, b, label="", color="#586674", dashed=False, pts=None):
    edges.append(dict(a=a, b=b, label=label, color=color, dashed=dashed, pts=pts or []))

W, H = 1680, 1180
# ---- zones (drawn first) ----
box("z_user", 20, 20, 520, 200, "User network  10.10.5.0/24", "", C["user"], C["userB"], "zone")
box("z_ad", 1140, 20, 520, 200, "Active Directory  corp.example", "", C["ad"], C["adB"], "zone")
box("z_lab", 20, 330, 1640, 830, "Lab network  10.10.1.0/24  (vSphere lab VLAN port group)", "", C["net"], C["netB"], "zone")
box("z_cp", 470, 450, 740, 250, "Kubernetes control plane  v1.32.13 / cri-o 1.32.1", "", C["cp"], C["cpB"], "zone")
box("z_wk", 470, 740, 740, 400, "Worker nodes  (application pods, Calico BGP)", "", C["wk"], C["wkB"], "zone")
box("z_etcd", 1250, 450, 390, 330, "External etcd cluster  v3.5.27  (TLS)", "", C["etcd"], C["etcdB"], "zone")

# ---- user side ----
box("users", 50, 70, 220, 120, "Lab users & admins", "Windows PCs, e.g. 10.10.5.7\nSSH client + browser\nAD login", "#ffffff", C["userB"])
box("browser", 300, 70, 210, 120, "Browser", "https://<app>.apps.corp.example\ntrusts Home Lab Root CA", "#ffffff", C["userB"])
# ---- AD ----
box("dc1", 1170, 70, 220, 120, "dc01", "10.10.5.251\nAD · DNS · NTP · Kerberos\nLDAPS 636 (lab CA cert)", "#ffffff", C["adB"])
box("dc2", 1410, 70, 220, 120, "dc02", "10.10.5.252\nAD · DNS · NTP · Kerberos\nLDAPS 636 (lab CA cert)", "#ffffff", C["adB"])
# ---- router ----
box("router", 700, 245, 280, 62, "Router / gateway 10.10.1.1", "routes 10.10.1.0/27 today → request /24", C["router"], C["routerB"])

# ---- bastion ----
box("bastion", 50, 390, 380, 300, "Bastion  10.10.1.11", "bastion.corp.example\n\n• SSH entry for all AD users (no sudo)\n• kubectl + kubelogin (AD login via Dex)\n• Helm, Velero CLI, etcdctl\n• S3 store versitygw :7070\n• 500 GB backup disk /srv/backup\n• Weekly backup timer  Sun 02:00 IST\n  (etcd snapshot + Velero, keep 8 wks)", "#ffffff", C["basB"])

# ---- control plane ----
box("vip", 690, 480, 300, 52, "API VIP  10.10.1.20:6443", "k8s-api.corp.example  (kube-vip, ARP)", C["vip"], C["vip"], "vip")
for i, (n, ip) in enumerate([("manager", ".14"), ("manager-2", ".21"), ("manager-3", ".22")]):
    box(f"m{i}", 495 + i * 240, 570, 210, 110, n, f"10.10.1{ip}\napiserver · scheduler\ncontroller-mgr · kube-vip", "#ffffff", C["cpB"])

# ---- workers ----
for i, (n, ip) in enumerate([("worker-a", ".15"), ("worker-b", ".16"), ("worker-c", ".17"), ("worker-d", ".18")]):
    box(f"w{i}", 490 + i * 180, 790, 160, 72, n, f"10.10.1{ip}", "#ffffff", C["wkB"])
box("pods", 490, 885, 700, 240, "Platform services running on the workers", 
    "• Dex ×2  –  AD login (OIDC), NodePort 32000 → dex.corp.example via VIP\n"
    "• HAProxy Unified Gateway ×2  –  Gateway \"apps\" :80/:443, wildcard TLS *.apps\n"
    "• MetalLB  –  L2 speakers, pool 10.10.1.25-29 (+.40-.49 after /24)\n"
    "• Velero server + node-agent  –  backups to Bastion S3\n"
    "• CoreDNS (corp.example → DCs) · Calico · kube-proxy\n"
    "• playground namespace  –  user apps (quota, Pod Security baseline)\n"
    "   e.g. hello.apps.corp.example", "#ffffff", C["wkB"], "node", True, 12)

# ---- gateway LB IP ----
box("lbip", 50, 760, 380, 110, "App gateway  10.10.1.25", "*.apps.corp.example  ports 80 / 443\nMetalLB LoadBalancer IP (announced by a worker)\n→ HAProxy Unified Gateway pods", "#ffffff", C["gwB"])
box("rbac", 50, 900, 380, 240, "Access model (AD groups → RBAC)",
    "Lab user (all Domain Users)\n  SSH: Bastion only, no sudo\n  K8s: view cluster (no Secrets)\n        + edit in namespace playground\n\n"
    "Lab administrator (K8s-Admins)\n  SSH + sudo on all 11 machines\n  K8s: cluster-admin\n\nEmergency: local accounts + admin.conf", "#ffffff", C["muted"], "node", True, 12)

# ---- etcd ----
for i, (n, ip, note) in enumerate([("etcd-1", ".12", "also: v1.29 worker (other cluster)"),
                                    ("etcd-2", ".13", "also: v1.29 worker (other cluster)"),
                                    ("etcd-3", ".19", "also: k3s server + NFS server")]):
    box(f"e{i}", 1275, 495 + i * 92, 340, 78, f"{n}  10.10.1{ip}", f":2379 client / :2380 peer\n{note}", "#ffffff", C["etcdB"])
box("note_etcd", 1250, 800, 390, 90, "Shared etcd VMs", "The etcd VMs also host other lab clusters.\nNext project: dedicated etcd VMs.", "#fff8d6", C["routerB"], "node", True, 12)

# ---- edges: explicit orthogonal routes (points) + label position ----
def route(a, b, pts, label="", color="#586674", dashed=False, lpos=None):
    edges.append(dict(a=a, b=b, pts=pts, label=label, color=color, dashed=dashed, lpos=lpos))
route("users", "router", [(160,190),(160,276),(700,276)], "SSH 22 / HTTPS 443", C["userB"], lpos=(430,276))
route("router", "bastion", [(760,307),(760,372),(240,372),(240,390)], "SSH 22 → Bastion", C["basB"], lpos=(600,372))
route("router", "lbip", [(720,307),(720,356),(452,356),(452,815),(430,815)], "HTTPS 443 / HTTP 80 → 10.10.1.25", C["gwB"], lpos=(452,735))
route("bastion", "vip", [(430,506),(690,506)], "kubectl :6443 (AD token)", C["cpB"], lpos=(560,494))
route("vip", "m0", [(840,532),(840,551),(600,551),(600,570)], "", C["cpB"])
route("vip", "m1", [(840,532),(840,570)], "", C["cpB"])
route("vip", "m2", [(840,532),(840,551),(1080,551),(1080,570)], "", C["cpB"])
route("m2", "z_etcd", [(1185,640),(1250,640)], "etcd TLS :2379", C["etcdB"], lpos=(1218,660))
route("lbip", "pods", [(430,850),(470,850),(470,1000),(490,1000)], "", C["gwB"])
route("pods", "dc1", [(1190,950),(1230,950),(1230,238),(1280,238),(1280,190)], "Dex → LDAPS :636", C["adB"], True, lpos=(1230,720))
route("z_lab", "dc2", [(1520,330),(1520,190)], "all 11 hosts: DNS · NTP · Kerberos · SSSD", C["adB"], True, lpos=(1520,262))

# ---------------- draw.io XML ----------------
def dio_style(n):
    base = "html=1;whiteSpace=wrap;fontFamily=Helvetica;"
    if n["kind"] == "zone":
        return base + f"rounded=1;arcSize=3;fillColor={n['fill']};strokeColor={n['stroke']};strokeWidth=2;dashed=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;fontStyle=1;fontSize=14;fontColor={n['stroke']};container=0;"
    if n["kind"] == "vip":
        return base + f"rounded=1;fillColor={n['fill']};strokeColor={n['stroke']};fontColor=#ffffff;fontSize=13;"
    return base + f"rounded=1;arcSize=6;fillColor={n['fill']};strokeColor={n['stroke']};strokeWidth=1.5;align=left;verticalAlign=top;spacingLeft=8;spacingTop=4;fontSize={n['fs']};fontColor={C['ink']};"
def dio_value(n):
    t = html.escape(n["title"]); s = html.escape(n["sub"]).replace("\n", "<br>")
    if n["kind"] == "zone": return t
    if n["kind"] == "vip": return f"<b>{t}</b><br><span style='font-size:11px'>{s}</span>"
    return f"<b>{t}</b>" + (f"<br><span style='font-size:{n['fs']-1}px;color:{C['muted']}'>{s}</span>" if s else "")
cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
for n in nodes:
    cells.append(f'<mxCell id="{n["id"]}" value="{escape(dio_value(n), {chr(34): "&quot;"})}" style="{dio_style(n)}" vertex="1" parent="1">'
                 f'<mxGeometry x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" as="geometry"/></mxCell>')
for i, e in enumerate(edges):
    st = f"edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor={e['color']};strokeWidth=2;fontSize=11;fontColor={e['color']};labelBackgroundColor=#ffffff;endArrow=block;endFill=1;" + ("dashed=1;" if e["dashed"] else "")
    cells.append(f'<mxCell id="edge{i}" value="{escape(e["label"])}" style="{st}" edge="1" parent="1" source="{e["a"]}" target="{e["b"]}">'
                 '<mxGeometry relative="1" as="geometry">' + (('<Array as="points">' + ''.join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in e["pts"][1:-1]) + '</Array>') if len(e["pts"]) > 2 else '') + '</mxGeometry></mxCell>')
xml = (f'<mxfile host="app.diagrams.net"><diagram name="Home Lab Infrastructure" id="lab">'
       f'<mxGraphModel dx="{W}" dy="{H}" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{W}" pageHeight="{H}" math="0" shadow="0">'
       f'<root>{"".join(cells)}</root></mxGraphModel></diagram></mxfile>')
open("lab-infrastructure.drawio", "w").write(xml)

# ---------------- SVG ----------------
byid = {n["id"]: n for n in nodes}
def center(n): return (n["x"] + n["w"] / 2, n["y"] + n["h"] / 2)
def anchor(n, toward):
    cx, cy = center(n); tx, ty = toward
    dx, dy = tx - cx, ty - cy
    if abs(dx) * n["h"] > abs(dy) * n["w"]:
        return (n["x"] + (n["w"] if dx > 0 else 0), cy)
    return (cx, n["y"] + (n["h"] if dy > 0 else 0))
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="IBM Plex Sans, Segoe UI, Helvetica, Arial, sans-serif" role="img" aria-label="LAB lab infrastructure diagram">',
       '<defs>' + "".join(f'<marker id="a{k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{v}"/></marker>' for k, v in C.items()) + '</defs>',
       f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
for n in nodes:
    if n["kind"] == "zone":
        out.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="10" fill="{n["fill"]}" stroke="{n["stroke"]}" stroke-width="2" stroke-dasharray="7 5"/>')
        out.append(f'<text x="{n["x"]+12}" y="{n["y"]+22}" font-size="14" font-weight="600" fill="{n["stroke"]}">{escape(n["title"])}</text>')
for n in nodes:
    if n["kind"] == "zone": continue
    if n["kind"] == "vip":
        out.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="8" fill="{n["fill"]}"/>')
        out.append(f'<text x="{n["x"]+n["w"]/2}" y="{n["y"]+22}" text-anchor="middle" font-size="14" font-weight="600" fill="#ffffff">{escape(n["title"])}</text>')
        out.append(f'<text x="{n["x"]+n["w"]/2}" y="{n["y"]+40}" text-anchor="middle" font-size="11.5" fill="#e3f1f2">{escape(n["sub"])}</text>')
        continue
    out.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="8" fill="{n["fill"]}" stroke="{n["stroke"]}" stroke-width="1.6"/>')
    out.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="5" height="{n["h"]}" rx="2" fill="{n["stroke"]}"/>')
    out.append(f'<text x="{n["x"]+14}" y="{n["y"]+21}" font-size="{n["fs"]+1}" font-weight="600" fill="{C["ink"]}">{escape(n["title"])}</text>')
    for j, line in enumerate(n["sub"].split("\n") if n["sub"] else []):
        out.append(f'<text x="{n["x"]+14}" y="{n["y"]+40+j*(n["fs"]+4.5)}" font-size="{n["fs"]-0.5}" fill="{C["muted"]}" xml:space="preserve">{escape(line)}</text>')
key = {v: k for k, v in C.items()}
for e in edges:
    d = "M" + " L".join(f"{x},{y}" for x, y in e["pts"])
    dash = ' stroke-dasharray="6 4"' if e["dashed"] else ""
    out.append(f'<path d="{d}" fill="none" stroke="{e["color"]}" stroke-width="2" stroke-linejoin="round"{dash} marker-end="url(#a{key[e["color"]]})"/>')
for e in edges:
    if e["label"]:
        lx, ly = e["lpos"]
        wlab = 6.6 * len(e["label"]) + 14
        out.append(f'<rect x="{lx-wlab/2}" y="{ly-11}" width="{wlab}" height="21" rx="4" fill="#ffffff" stroke="{e["color"]}" stroke-width="0.9"/>')
        out.append(f'<text x="{lx}" y="{ly+4}" text-anchor="middle" font-size="11.5" font-weight="600" fill="{e["color"]}">{escape(e["label"])}</text>')
out.append(f'<text x="{W-20}" y="{H-8}" text-anchor="end" font-size="11" fill="{C["muted"]}">Home Lab · Kubernetes platform · September 2026</text>')
out.append("</svg>")
open("lab-infrastructure.svg", "w").write("\n".join(out))
print("ok", len(nodes), "shapes", len(edges), "connectors")
