using System;
using System.IO;
using System.Collections;
using System.Reflection;
using System.Numerics;
using CodeWalker.GameFiles;

// Headless scenario-point authoring for the NTeam MRPD scenario ymt.
//
// MODES:
//   probe   <ymt>                     — dump ScenarioNode/MyPoint structure
//   roundtrip <ymt>                   — mutate a node, Save, reload, verify (no write)
//
// Round-trip MUST pass before we ever write the live file (a bad ymt crashes
// clients on join).
class Program
{
    static int Main(string[] args)
    {
        string mode = args.Length > 0 ? args[0] : "probe";
        string path = args.Length > 1 ? args[1] : null;

        var ymt = Load(path);
        var sr = ymt.ScenarioRegion;
        var nodes = GetProp(sr, "Nodes") as IList;
        int origWithPoint = 0;
        foreach (var n in nodes) if (GetProp(n, "MyPoint") != null) origWithPoint++;
        Console.Error.WriteLine($"loaded: {nodes?.Count ?? 0} nodes, {origWithPoint} with MyPoint");
        if (nodes == null || nodes.Count == 0) { Console.Error.WriteLine("no nodes"); return 2; }

        var node0 = nodes[0];
        var nodeT = node0.GetType();

        // addpoints <ymt> <coordsFile> <scenarioName> <outYmt>
        // Clones a known-good point per coord, sets position/heading/type to a
        // seated scenario, adds via the container API, then STRICT round-trip
        // validation (orig+N points, all reloadable, new points carry the type)
        // before writing outYmt. A bad ymt crashes clients, so no write unless valid.
        if (mode == "addpoints")
        {
            string coordsFile = args[2];
            string scenName = args[3];
            string outYmt = args[4];
            // optional: interior hash the new points belong to (so the game spawns
            // them when that MLO interior is loaded — else deep-interior points cull).
            uint interiorHash = args.Length > 5 ? uint.Parse(args[5]) : 0;

            var asm = typeof(YmtFile).Assembly;
            var region = ymt.CScenarioPointRegion;
            var container = GetProp(region, "Points");
            var lookups = GetProp(region, "LookUps");

            // Read ALL four lookup tables (index -> hash). Save() rebuilds EVERY one
            // of these from the points' refs, so a headless resave that leaves refs
            // null WIPES model-sets/interiors/groups (the lobby regression). We must
            // repopulate every ref from its loaded index on every existing point.
            var typeNamesArr = (Array)GetProp(lookups, "TypeNames");
            var mhType = typeNamesArr.GetValue(0).GetType();
            uint[] typeNames = ReadHashes(typeNamesArr);
            uint[] modelNames = ReadHashes(GetProp(lookups, "PedModelSetNames") as Array);
            uint[] interiorNames = ReadHashes(GetProp(lookups, "InteriorNames") as Array);
            uint[] groupNames = ReadHashes(GetProp(lookups, "GroupNames") as Array);
            uint seatHash = JenkHash.GenHash(scenName.ToLowerInvariant());
            Console.Error.WriteLine($"orig tables: {typeNames.Length} types, {modelNames.Length} modelsets, {interiorNames.Length} interiors, {groupNames.Length} groups; seat {seatHash}");

            var myPoints = (Array)GetProp(container, "MyPoints");
            foreach (var mpEx in myPoints)
            {
                int tid = Convert.ToInt32(GetProp(mpEx, "TypeId"));
                if (tid >= 0 && tid < typeNames.Length) SetProp(mpEx, "Type", MakeTypeRef(asm, mhType, typeNames[tid], null));
                int msid = Convert.ToInt32(GetProp(mpEx, "ModelSetId"));
                if (msid > 0 && msid < modelNames.Length) SetProp(mpEx, "ModelSet", MakeModelSetRef(asm, mhType, modelNames[msid]));
                int iid = Convert.ToInt32(GetProp(mpEx, "InteriorId"));
                if (iid > 0 && iid < interiorNames.Length) SetProp(mpEx, "InteriorName", MakeMetaHash(mhType, interiorNames[iid]));
                int gid = Convert.ToInt32(GetProp(mpEx, "GroupId"));
                if (gid > 0 && gid < groupNames.Length) SetProp(mpEx, "GroupName", MakeMetaHash(mhType, groupNames[gid]));
            }
            Console.Error.WriteLine($"rebuilt Type/ModelSet/Interior/Group refs on {myPoints.Length} existing points");

            // Clone source + add the seated points with a real seated Type ref.
            var src = GetProp(node0, "MyPoint");
            var mpType = src.GetType();
            var copyCtor = mpType.GetConstructor(new[] { region.GetType(), mpType });
            if (copyCtor == null)
                foreach (var c in mpType.GetConstructors())
                { var ps = c.GetParameters(); if (ps.Length == 2 && ps[1].ParameterType == mpType) { copyCtor = c; break; } }
            var seatRef = MakeTypeRef(asm, mhType, seatHash, scenName);
            Console.Error.WriteLine($"seatRef NameHash = {HashVal(GetProp(seatRef, "NameHash"))} (want {seatHash}), IsGroup={GetProp(seatRef, "IsGroup")}");
            var addMy = container.GetType().GetMethod("AddMyPoint");
            int added = 0;
            foreach (var line in File.ReadAllLines(coordsFile))
            {
                var t = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (t.Length < 4) continue;
                float px = float.Parse(t[0]), py = float.Parse(t[1]), pz = float.Parse(t[2]), hdeg = float.Parse(t[3]);
                var np = copyCtor.Invoke(new object[] { region, src });
                SetProp(np, "Type", MakeTypeRef(asm, mhType, seatHash, scenName));
                SetProp(np, "Position", FromVec(mpType.GetProperty("Position").PropertyType, new Vector3(px, py, pz)));
                SetProp(np, "Direction", (float)(hdeg * Math.PI / 180.0));
                SetProp(np, "Probability", (byte)100);
                SetProp(np, "TimeStart", (byte)0);
                SetProp(np, "TimeEnd", (byte)24);
                SetProp(np, "Radius", (byte)2);
                if (interiorHash != 0) SetProp(np, "InteriorName", MakeMetaHash(mhType, interiorHash));
                addMy.Invoke(container, new[] { np });
                added++;
            }
            Console.Error.WriteLine($"added {added} seated points");

            // Rebuild the node/vertex structures from the updated point container so
            // Save()'s lookup rebuild sees the NEW points' type refs (else the load-
            // time Nodes list is stale and the seated type never registers).
            CallIf(sr, "BuildNodes");
            CallIf(sr, "BuildBVH");
            CallIf(sr, "BuildVertices");

            // Save + STRICT round-trip validation (the gate that prevents shipping
            // a client-crashing ymt): reload, TypeNames must survive + contain the
            // seated type, point count exact, all N seated points present + placed.
            byte[] outBytes = ymt.Save();
            var ymt2 = new YmtFile();
            byte[] d2 = outBytes; var e2 = RpfFile.CreateResourceFileEntry(ref d2, 0);
            d2 = ResourceBuilder.Decompress(d2); ymt2.Load(d2, e2);
            var region2 = ymt2.CScenarioPointRegion;
            var lk2 = GetProp(region2, "LookUps");
            var tn2 = GetProp(lk2, "TypeNames") as Array;
            var ms2 = GetProp(lk2, "PedModelSetNames") as Array;
            var in2 = GetProp(lk2, "InteriorNames") as Array;
            int seatTid2 = -1;
            if (tn2 != null) for (int i = 0; i < tn2.Length; i++) if (HashVal(tn2.GetValue(i)) == seatHash) seatTid2 = i;
            var nodes2 = GetProp(ymt2.ScenarioRegion, "Nodes") as IList;
            int withPoint2 = 0, withSeat = 0, withInterior2 = 0, withModel2 = 0;
            foreach (var n in nodes2)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                withPoint2++;
                if (seatTid2 >= 0 && Convert.ToInt32(GetProp(m, "TypeId")) == seatTid2) withSeat++;
                if (Convert.ToInt32(GetProp(m, "InteriorId")) != 0) withInterior2++;
                if (Convert.ToInt32(GetProp(m, "ModelSetId")) != 0) withModel2++;
            }
            int expect = origWithPoint + added;
            // Count what the ORIGINAL had, so we assert nothing regressed.
            int origInterior = 0, origModel = 0;
            foreach (var n in nodes) { var m = GetProp(n, "MyPoint"); if (m == null) continue; if (Convert.ToInt32(GetProp(m, "InteriorId")) != 0) origInterior++; if (Convert.ToInt32(GetProp(m, "ModelSetId")) != 0) origModel++; }
            bool ok = tn2 != null && seatTid2 >= 0 && withPoint2 == expect && withSeat == added
                      && withInterior2 >= origInterior && withModel2 >= origModel
                      && (ms2 != null && ms2.Length >= 20) && (in2 != null && in2.Length >= 3);
            Console.Error.WriteLine($"reload: TypeNames={(tn2 == null ? "NULL" : tn2.Length.ToString())}(seat@{seatTid2}), ModelSets={(ms2 == null ? "NULL" : ms2.Length.ToString())}, Interiors={(in2 == null ? "NULL" : in2.Length.ToString())}");
            Console.Error.WriteLine($"        points={withPoint2}/{expect}, seated={withSeat}/{added}, interior-pts={withInterior2}/{origInterior}, modelset-pts={withModel2}/{origModel}");
            if (!ok) { Console.Error.WriteLine("VALIDATION FAILED (regression or missing) — not writing"); return 3; }
            File.WriteAllBytes(outYmt, outBytes);
            Console.Error.WriteLine($"VALIDATION PASS — wrote {outYmt} ({outBytes.Length} bytes)");
            return 0;
        }

        // dumpseat <ymt> <typeName> — print positions of points carrying that type.
        if (mode == "dumpseat")
        {
            uint want = JenkHash.GenHash(args[2].ToLowerInvariant());
            var lk = GetProp(ymt.CScenarioPointRegion, "LookUps");
            Console.Error.WriteLine("LookUps = " + (lk == null ? "NULL" : lk.GetType().Name));
            var tn = GetProp(lk, "TypeNames") as Array;
            if (tn == null) { Console.Error.WriteLine("TypeNames = NULL — lookup table LOST on save"); return 4; }
            int tid = -1; for (int i = 0; i < tn.Length; i++) if (HashVal(tn.GetValue(i)) == want) tid = i;
            Console.Error.WriteLine($"type '{args[2]}' hash {want} -> TypeId {tid} (of {tn.Length} TypeNames)");
            if (tid < 0) { Console.Error.WriteLine("TYPE NOT IN TABLE — points would reference a missing type"); }
            int c = 0;
            foreach (var n in nodes)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null || Convert.ToInt32(GetProp(m, "TypeId")) != tid) continue;
                var p = ToVec(GetProp(m, "Position"));
                Console.WriteLine($"{p.X:F2}\t{p.Y:F2}\t{p.Z:F2}\tdir={GetProp(m, "Direction")}\tprob={GetProp(m, "Probability")}\ttime={GetProp(m, "TimeStart")}-{GetProp(m, "TimeEnd")}");
                c++;
            }
            Console.Error.WriteLine($"{c} points of that type");
            return 0;
        }

        // audit <ymt> — InteriorName / ModelSet / TimeRange distribution + how many
        // points fall inside the station footprint (do interior points set interior?)
        if (mode == "audit")
        {
            var region = ymt.CScenarioPointRegion;
            var lk = GetProp(region, "LookUps");
            var interiorNames = GetProp(lk, "InteriorNames") as Array;
            Console.Error.WriteLine($"InteriorNames table: {(interiorNames == null ? "NULL" : interiorNames.Length + " entries")}");
            if (interiorNames != null) for (int i = 0; i < interiorNames.Length; i++) Console.Error.WriteLine($"  interior[{i}] = {HashVal(interiorNames.GetValue(i))}");
            var mdlNames = GetProp(lk, "PedModelSetNames") as Array;
            Console.Error.WriteLine($"PedModelSetNames: {(mdlNames == null ? "NULL" : mdlNames.Length + " entries")}");

            int withInterior = 0, insideBox = 0, insideWithInterior = 0;
            foreach (var n in nodes)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                int iid = Convert.ToInt32(GetProp(m, "InteriorId"));
                var p = ToVec(GetProp(m, "Position"));
                bool inside = p.X > 440 && p.X < 485 && p.Y > -985 && p.Y < -925 && p.Z > 28;
                if (iid != 0) withInterior++;
                if (inside) { insideBox++; if (iid != 0) insideWithInterior++; }
            }
            Console.Error.WriteLine($"points: {withInterior} have InteriorId!=0; {insideBox} inside station box, of which {insideWithInterior} set an interior");
            // Which interior do points NEAR the press room (x>470,y>-945) use?
            var seen = new System.Collections.Generic.Dictionary<uint, int>();
            foreach (var n in nodes)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                var p = ToVec(GetProp(m, "Position"));
                if (!(p.X > 468 && p.Y > -950 && p.Y < -925 && p.Z > 28)) continue;
                uint inm = HashVal(GetProp(m, "InteriorName"));
                seen[inm] = seen.TryGetValue(inm, out var c) ? c + 1 : 1;
            }
            Console.Error.WriteLine("InteriorName used by points near the press room:");
            foreach (var kv in seen) Console.Error.WriteLine($"  {kv.Key} -> {kv.Value} points");
            // Every interior point: group by InteriorName, show a sample position so we
            // can see which interior hash the MRPD-building points use.
            var inArr = GetProp(lk, "InteriorNames") as Array;
            var byInt = new System.Collections.Generic.Dictionary<int, (int n, Vector3 lo, Vector3 hi)>();
            foreach (var n in nodes)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                int iid = Convert.ToInt32(GetProp(m, "InteriorId"));
                if (iid == 0) continue;
                var p = ToVec(GetProp(m, "Position"));
                if (byInt.TryGetValue(iid, out var e))
                    byInt[iid] = (e.n + 1, new Vector3(Math.Min(e.lo.X, p.X), Math.Min(e.lo.Y, p.Y), Math.Min(e.lo.Z, p.Z)), new Vector3(Math.Max(e.hi.X, p.X), Math.Max(e.hi.Y, p.Y), Math.Max(e.hi.Z, p.Z)));
                else byInt[iid] = (1, p, p);
            }
            Console.Error.WriteLine("Interior points grouped by InteriorId (id -> hash, count, bbox):");
            foreach (var kv in byInt)
            {
                uint h = kv.Key < inArr.Length ? HashVal(inArr.GetValue(kv.Key)) : 0;
                Console.Error.WriteLine($"  id{kv.Key} (hash {h}) -> {kv.Value.n} pts, x[{kv.Value.lo.X:F0}..{kv.Value.hi.X:F0}] y[{kv.Value.lo.Y:F0}..{kv.Value.hi.Y:F0}] z[{kv.Value.lo.Z:F0}..{kv.Value.hi.Z:F0}]");
            }
            return 0;
        }

        if (mode == "probe6")
        {
            var asm = typeof(YmtFile).Assembly;
            var mp = GetProp(node0, "MyPoint");
            // find a point that USES a model set + interior + group
            foreach (var n in nodes)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                if (Convert.ToInt32(GetProp(m, "ModelSetId")) != 0 || Convert.ToInt32(GetProp(m, "InteriorId")) != 0) { mp = m; break; }
            }
            Console.Error.WriteLine("sample point: ModelSetId=" + GetProp(mp, "ModelSetId") + " ModelSet=" + GetProp(mp, "ModelSet") + " InteriorId=" + GetProp(mp, "InteriorId") + " InteriorName=" + GetProp(mp, "InteriorName") + " GroupId=" + GetProp(mp, "GroupId") + " GroupName=" + GetProp(mp, "GroupName"));
            var ms = GetProp(mp, "ModelSet");
            Console.Error.WriteLine("ModelSet ref type = " + (ms?.GetType().FullName ?? "null"));
            var amsType = asm.GetType("CodeWalker.World.AmbientModelSet") ?? mp.GetType().GetProperty("ModelSet").PropertyType;
            Console.Error.WriteLine("AmbientModelSet = " + amsType.FullName);
            foreach (var c in amsType.GetConstructors()) Console.Error.WriteLine("  ctor(" + string.Join(",", Array.ConvertAll(c.GetParameters(), pp => pp.ParameterType.Name)) + ")");
            foreach (var p in amsType.GetProperties(BindingFlags.Public | BindingFlags.Instance)) Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name} (set={p.CanWrite})");
            return 0;
        }

        if (mode == "probe5")
        {
            var asm = typeof(YmtFile).Assembly;
            var st = asm.GetType("CodeWalker.World.ScenarioType");
            Console.Error.WriteLine("ScenarioType = " + (st == null ? "NOT FOUND" : st.FullName));
            if (st != null)
            {
                Console.Error.WriteLine("=== constructors ===");
                foreach (var c in st.GetConstructors())
                    Console.Error.WriteLine($"  ({string.Join(",", Array.ConvertAll(c.GetParameters(), pp => pp.ParameterType.Name + " " + pp.Name))})");
                Console.Error.WriteLine("=== settable props ===");
                foreach (var p in st.GetProperties(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  {p.PropertyType.Name} {p.Name} (set={p.CanWrite})");
                foreach (var f in st.GetFields(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  field {f.FieldType.Name} {f.Name}");
            }
            return 0;
        }

        if (mode == "probe4")
        {
            var mp = GetProp(node0, "MyPoint");
            var typeProp = mp.GetType().GetProperty("Type");
            var trt = typeProp.PropertyType;
            Console.Error.WriteLine("ScenarioTypeRef type = " + trt.FullName);
            Console.Error.WriteLine("=== constructors ===");
            foreach (var c in trt.GetConstructors())
                Console.Error.WriteLine($"  ({string.Join(",", Array.ConvertAll(c.GetParameters(), pp => pp.ParameterType.Name + " " + pp.Name))})");
            Console.Error.WriteLine("=== settable props ===");
            foreach (var p in trt.GetProperties(BindingFlags.Public | BindingFlags.Instance))
                Console.Error.WriteLine($"  {p.PropertyType.Name} {p.Name} (set={p.CanWrite})");
            // How does the region rebuild lookups? look for Build/Update methods.
            var region = ymt.CScenarioPointRegion;
            Console.Error.WriteLine("=== region Build/Update/Save methods ===");
            foreach (var m in region.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance))
                if (m.Name.Contains("Build") || m.Name.Contains("Update") || m.Name.Contains("Lookup") || m.Name.Contains("LookUp"))
                    Console.Error.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(",", Array.ConvertAll(m.GetParameters(), pp => pp.ParameterType.Name))})");
            return 0;
        }

        if (mode == "probe3")
        {
            var region = ymt.CScenarioPointRegion;
            var mp = GetProp(node0, "MyPoint");
            Console.Error.WriteLine("=== a real MyPoint's values ===");
            foreach (var pn in new[] { "TypeId", "Type", "Position", "Direction", "ModelSetId", "InteriorId", "InteriorName", "Probability", "Radius", "TimeStart", "TimeEnd", "Flags" })
            {
                var v = GetProp(mp, pn);
                Console.Error.WriteLine($"  {pn} = {v}  ({(v == null ? "null" : v.GetType().Name)})");
            }
            var typeRef = GetProp(mp, "Type");
            if (typeRef != null)
            {
                Console.Error.WriteLine("=== ScenarioTypeRef (" + typeRef.GetType().Name + ") members ===");
                foreach (var p in typeRef.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name} = {SafeGet(p, typeRef)}");
            }
            // MCScenarioPoint constructors
            Console.Error.WriteLine("=== MCScenarioPoint constructors ===");
            foreach (var c in mp.GetType().GetConstructors())
                Console.Error.WriteLine($"  ({string.Join(",", Array.ConvertAll(c.GetParameters(), pp => pp.ParameterType.Name + " " + pp.Name))})");
            // LookUps
            var lookups = GetProp(region, "LookUps");
            if (lookups != null)
            {
                Console.Error.WriteLine("=== LookUps (" + lookups.GetType().Name + ") members ===");
                foreach (var p in lookups.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name}");
                foreach (var m in lookups.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance))
                    if (m.Name.Contains("Add") || m.Name.Contains("Type") || m.Name.Contains("Get")) Console.Error.WriteLine($"  method {m.ReturnType.Name} {m.Name}({string.Join(",", Array.ConvertAll(m.GetParameters(), pp => pp.ParameterType.Name))})");
            }
            return 0;
        }

        if (mode == "probe2")
        {
            var region = ymt.CScenarioPointRegion;
            var points = GetProp(region, "Points");
            Console.Error.WriteLine("=== Points container (" + points.GetType().Name + ") ===");
            foreach (var p in points.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name} (set={p.CanWrite})");
            foreach (var m in points.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance))
                if (m.Name.Contains("Add") || m.Name.Contains("Point") || m.Name.Contains("Remove"))
                    Console.Error.WriteLine($"  method {m.ReturnType.Name} {m.Name}({string.Join(",", Array.ConvertAll(m.GetParameters(), pp => pp.ParameterType.Name))})");
            // MyPoint.Data (CScenarioPoint) fields
            var mp = GetProp(node0, "MyPoint");
            var data = GetProp(mp, "Data");
            Console.Error.WriteLine("=== CScenarioPoint Data (" + data.GetType().Name + ") fields ===");
            foreach (var f in data.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
                Console.Error.WriteLine($"  field {f.FieldType.Name} {f.Name} = {f.GetValue(data)}");
            return 0;
        }

        if (mode == "probe")
        {
            Console.Error.WriteLine("=== ScenarioNode members ===");
            foreach (var p in nodeT.GetProperties(BindingFlags.Public | BindingFlags.Instance))
                Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name}  (set={p.CanWrite})");
            var myPoint = GetProp(node0, "MyPoint");
            if (myPoint != null)
            {
                Console.Error.WriteLine("=== MyPoint (" + myPoint.GetType().Name + ") members ===");
                foreach (var p in myPoint.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  prop {p.PropertyType.Name} {p.Name}  (set={p.CanWrite})");
                foreach (var f in myPoint.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
                    Console.Error.WriteLine($"  field {f.FieldType.Name} {f.Name}");
            }
            return 0;
        }

        if (mode == "roundtrip" || mode == "resave")
        {
            Vector3 moved = Vector3.Zero; bool mutated = false;
            if (mode == "roundtrip")
            {
                var mp = GetProp(node0, "MyPoint");
                var mpPos = mp.GetType().GetProperty("Position");
                var before = ToVec(mpPos.GetValue(mp));
                moved = new Vector3(before.X + 5.0f, before.Y + 7.0f, before.Z + 1.0f);
                mpPos.SetValue(mp, FromVec(mpPos.PropertyType, moved));
                mutated = true;
                Console.Error.WriteLine($"mutated MyPoint {before} -> {moved}");
            }

            byte[] outBytes = ymt.Save();
            Console.Error.WriteLine($"Save() -> {outBytes.Length} bytes");

            var ymt2 = new YmtFile();
            byte[] d2 = outBytes;
            var e2 = RpfFile.CreateResourceFileEntry(ref d2, 0);
            d2 = ResourceBuilder.Decompress(d2);
            ymt2.Load(d2, e2);
            var nodes2 = GetProp(ymt2.ScenarioRegion, "Nodes") as IList;
            int withPoint = 0;
            foreach (var n in nodes2) if (GetProp(n, "MyPoint") != null) withPoint++;
            Console.Error.WriteLine($"reloaded: {nodes2.Count} nodes, {withPoint} with MyPoint (orig had {nodes.Count})");
            var mp2 = GetProp(nodes2[0], "MyPoint");
            if (mp2 != null)
            {
                var after = ToVec(mp2.GetType().GetProperty("Position").GetValue(mp2));
                Console.Error.WriteLine($"reloaded node0 MyPoint = {after}" + (mutated ? $"  (expected {moved})" : ""));
            }
            else Console.Error.WriteLine("reloaded node0 MyPoint = NULL");
            var tnCheck = GetProp(GetProp(ymt2.CScenarioPointRegion, "LookUps"), "TypeNames") as Array;
            Console.Error.WriteLine("reloaded TypeNames = " + (tnCheck == null ? "NULL" : tnCheck.Length + " entries"));
            if (args.Length > 2) { File.WriteAllBytes(args[2], outBytes); Console.Error.WriteLine("wrote " + args[2]); }
            bool ok = nodes2.Count == nodes.Count && withPoint > 0;
            Console.Error.WriteLine(ok ? "SAVE STRUCTURE OK" : "SAVE STRUCTURE BROKEN");
            return ok ? 0 : 3;
        }

        Console.Error.WriteLine("unknown mode");
        return 1;
    }

    static YmtFile Load(string path)
    {
        byte[] data = File.ReadAllBytes(path);
        var ymt = new YmtFile();
        var entry = RpfFile.CreateResourceFileEntry(ref data, 0);
        data = ResourceBuilder.Decompress(data);
        ymt.Load(data, entry);
        return ymt;
    }
    static object GetProp(object o, string n) => o?.GetType().GetProperty(n)?.GetValue(o);
    static object SafeGet(PropertyInfo p, object o) { try { return p.GetValue(o); } catch { return "?"; } }
    static void SetProp(object o, string n, object v)
    {
        var p = o.GetType().GetProperty(n);
        if (p == null) { Console.Error.WriteLine("no prop " + n); return; }
        // coerce simple numeric types to the property type
        if (v != null && p.PropertyType != v.GetType() && v is IConvertible && p.PropertyType.IsPrimitive)
            v = Convert.ChangeType(v, p.PropertyType);
        p.SetValue(o, v);
    }
    static uint HashVal(object mh)
    {
        if (mh == null) return 0;
        var h = mh.GetType().GetProperty("Hash")?.GetValue(mh);
        if (h != null) return Convert.ToUInt32(h);
        try { return Convert.ToUInt32(mh); } catch { return 0; }
    }
    static uint[] ReadHashes(Array arr)
    {
        if (arr == null) return new uint[0];
        var o = new uint[arr.Length];
        for (int i = 0; i < arr.Length; i++) o[i] = HashVal(arr.GetValue(i));
        return o;
    }

    // Fabricate an AmbientModelSet ref (same pattern as ScenarioType) so Save
    // rebuilds the PedModelSetNames table from it.
    static object MakeModelSetRef(Assembly asm, Type mhType, uint hash)
    {
        var t = asm.GetType("CodeWalker.World.AmbientModelSet");
        var o = Activator.CreateInstance(t);
        t.GetProperty("NameHash").SetValue(o, MakeMetaHash(mhType, hash));
        return o;
    }

    // Fabricate a ScenarioTypeRef backed by a minimal ScenarioType with the given
    // hash, so YmtFile.Save() rebuilds the TypeNames lookup table from it.
    static object MakeTypeRef(Assembly asm, Type mhType, uint hash, string name)
    {
        var stType = asm.GetType("CodeWalker.World.ScenarioType");
        var st = Activator.CreateInstance(stType);
        stType.GetProperty("NameHash").SetValue(st, MakeMetaHash(mhType, hash));
        if (name != null) { stType.GetProperty("Name").SetValue(st, name); stType.GetProperty("NameLower").SetValue(st, name.ToLowerInvariant()); }
        stType.GetProperty("IsVehicle").SetValue(st, false);
        var refType = asm.GetType("CodeWalker.World.ScenarioTypeRef");
        return refType.GetConstructor(new[] { stType }).Invoke(new[] { st });
    }

    static object MakeMetaHash(Type mhType, uint hash)
    {
        foreach (var c in mhType.GetConstructors())
        { var ps = c.GetParameters(); if (ps.Length == 1 && (ps[0].ParameterType == typeof(uint) || ps[0].ParameterType == typeof(int))) return c.Invoke(new object[] { ps[0].ParameterType == typeof(int) ? (object)(int)hash : hash }); }
        var o = Activator.CreateInstance(mhType);
        var hp = mhType.GetProperty("Hash"); if (hp != null && hp.CanWrite) hp.SetValue(o, hash);
        return o;
    }
    static void CallIf(object o, string n) { var m = o.GetType().GetMethod(n, Type.EmptyTypes); if (m != null) m.Invoke(o, null); }
    static Vector3 ToVec(object v) { var t = v.GetType(); return new Vector3((float)t.GetField("X").GetValue(v), (float)t.GetField("Y").GetValue(v), (float)t.GetField("Z").GetValue(v)); }
    static object FromVec(Type t, Vector3 v)
    {
        var o = Activator.CreateInstance(t);
        t.GetField("X").SetValue(o, v.X); t.GetField("Y").SetValue(o, v.Y); t.GetField("Z").SetValue(o, v.Z);
        var w = t.GetField("W"); if (w != null) w.SetValue(o, 1.0f);
        return o;
    }
}
