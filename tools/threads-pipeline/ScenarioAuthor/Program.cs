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

            var asm = typeof(YmtFile).Assembly;
            var region = ymt.CScenarioPointRegion;
            var container = GetProp(region, "Points");
            var lookups = GetProp(region, "LookUps");

            // Map the loaded TypeId -> type hash (needed to rebuild Type refs).
            var typeNamesArr = (Array)GetProp(lookups, "TypeNames");
            var mhType = typeNamesArr.GetValue(0).GetType();
            uint[] typeIdToHash = new uint[typeNamesArr.Length];
            for (int i = 0; i < typeNamesArr.Length; i++) typeIdToHash[i] = HashVal(typeNamesArr.GetValue(i));
            uint seatHash = JenkHash.GenHash(scenName.ToLowerInvariant());
            Console.Error.WriteLine($"orig TypeNames: {typeNamesArr.Length}; seat hash {seatHash}");

            // CRITICAL: Save() rebuilds the lookup tables from each point's resolved
            // Type ref (a headless load only sets the numeric TypeId), so a plain
            // resave LOSES TypeNames. Give every existing point a fabricated Type ref
            // matching its hash so Save rebuilds the table intact.
            var myPoints = (Array)GetProp(container, "MyPoints");
            foreach (var mpEx in myPoints)
            {
                int tid = Convert.ToInt32(GetProp(mpEx, "Type") == null ? GetProp(mpEx, "TypeId") : GetProp(mpEx, "TypeId"));
                if (tid >= 0 && tid < typeIdToHash.Length)
                    SetProp(mpEx, "Type", MakeTypeRef(asm, mhType, typeIdToHash[tid], null));
            }
            Console.Error.WriteLine($"rebuilt Type refs on {myPoints.Length} existing points");

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
            int seatTid2 = -1;
            if (tn2 != null) for (int i = 0; i < tn2.Length; i++) if (HashVal(tn2.GetValue(i)) == seatHash) seatTid2 = i;
            var nodes2 = GetProp(ymt2.ScenarioRegion, "Nodes") as IList;
            int withPoint2 = 0, withSeat = 0;
            foreach (var n in nodes2)
            {
                var m = GetProp(n, "MyPoint");
                if (m == null) continue;
                withPoint2++;
                if (seatTid2 >= 0 && Convert.ToInt32(GetProp(m, "TypeId")) == seatTid2) withSeat++;
            }
            int expect = origWithPoint + added;
            bool ok = tn2 != null && seatTid2 >= 0 && withPoint2 == expect && withSeat == added;
            Console.Error.WriteLine($"reload: TypeNames={(tn2 == null ? "NULL" : tn2.Length.ToString())}, seatTypeId={seatTid2}, {withPoint2} points (expect {expect}), {withSeat} seated (expect {added})");
            if (!ok) { Console.Error.WriteLine("VALIDATION FAILED — not writing"); return 3; }
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
