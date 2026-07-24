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
