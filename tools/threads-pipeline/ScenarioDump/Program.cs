using System;
using System.IO;
using System.Collections;
using System.Reflection;
using CodeWalker.GameFiles;

// Dumps NTeam's creator-placed scenario points for the Mission Row station:
//   scenarioType <TAB> x y z <TAB> headingDeg
// Filtered to the station bounding box. These are the exact NPC spots (sit in
// this chair / stand at this desk, facing correctly) the MLO designed.
class Program
{
    static int Main(string[] args)
    {
        byte[] data = File.ReadAllBytes(args[0]);
        var ymt = new YmtFile();
        var entry = RpfFile.CreateResourceFileEntry(ref data, 0);
        data = ResourceBuilder.Decompress(data);
        ymt.Load(data, entry);

        var sr = ymt.ScenarioRegion;
        var nodes = sr.GetType().GetProperty("Nodes")?.GetValue(sr) as IList;
        if (nodes == null) { Console.Error.WriteLine("no Nodes"); return 3; }

        var nodeT = nodes.Count > 0 ? nodes[0].GetType() : null;
        var pPos = nodeT.GetProperty("Position");
        var pOri = nodeT.GetProperty("Orientation");
        var pMy = nodeT.GetProperty("MyPoint");
        var pFull = nodeT.GetProperty("FullTypeName");
        var pShort = nodeT.GetProperty("ShortTypeName");

        // seed scenario type names so a resolved type-hash prints readable
        string[] scen = {
            "WORLD_HUMAN_SEAT_BENCH","WORLD_HUMAN_SEAT_LEDGE","WORLD_HUMAN_SEAT_WALL","WORLD_HUMAN_SEAT_STEPS",
            "WORLD_HUMAN_STAND_IMPATIENT","WORLD_HUMAN_STAND_IMPATIENT_UPRIGHT","WORLD_HUMAN_STAND_MOBILE",
            "WORLD_HUMAN_STAND_MOBILE_UPRIGHT","WORLD_HUMAN_STAND_FIRE","WORLD_HUMAN_GUARD_STAND",
            "WORLD_HUMAN_GUARD_STAND_ARMY","WORLD_HUMAN_GUARD_PATROL","WORLD_HUMAN_CLIPBOARD","WORLD_HUMAN_COP_IDLES",
            "WORLD_HUMAN_AA_COFFEE","WORLD_HUMAN_AA_SMOKE","WORLD_HUMAN_DRINKING","WORLD_HUMAN_SMOKING",
            "WORLD_HUMAN_SMOKING_POT","WORLD_HUMAN_LEANING","WORLD_HUMAN_MOBILE_FILM_SHOCKING","WORLD_HUMAN_TOURIST_MAP",
            "WORLD_HUMAN_TOURIST_MOBILE","WORLD_HUMAN_PAPARAZZI","WORLD_HUMAN_JANITOR","WORLD_HUMAN_MAID_CLEAN",
            "WORLD_HUMAN_SECURITY_SHINE_TORCH","WORLD_HUMAN_HANG_OUT_STREET","WORLD_HUMAN_WINDOW_SHOP_BROWSE",
            "WORLD_HUMAN_BINOCULARS","WORLD_HUMAN_CHEERING","WORLD_HUMAN_DRUG_DEALER","WORLD_HUMAN_HUMAN_STATUE",
            "WORLD_HUMAN_MUSICIAN","WORLD_HUMAN_PARTYING","WORLD_HUMAN_PICNIC","WORLD_HUMAN_STUPOR","WORLD_HUMAN_SUNBATHE",
            "WORLD_HUMAN_YOGA","WORLD_HUMAN_JOG_STANDING","WORLD_HUMAN_PUSH_UPS","WORLD_HUMAN_SIT_UPS","WORLD_HUMAN_MUSCLE_FLEX",
            "WORLD_HUMAN_HIKER_STANDING","WORLD_HUMAN_VEHICLE_MECHANIC","WORLD_HUMAN_WELDING","WORLD_HUMAN_HAMMERING",
            "WORLD_HUMAN_GARDENER_PLANT","WORLD_HUMAN_GARDENER_LEAF_BLOWER","WORLD_HUMAN_CONST_DRILL",
            "WORLD_HUMAN_CAR_PARK_ATTENDANT","WORLD_HUMAN_BUM_STANDING","WORLD_HUMAN_BUM_SLUMPED","WORLD_HUMAN_BUM_FREEWAY",
            "CODE_HUMAN_STAND_MOBILE","CODE_HUMAN_STAND_IMPATIENT","CODE_HUMAN_STAND_COWER","CODE_HUMAN_MEDIC_TEND_TO_DEAD",
            "WORLD_HUMAN_DRINKING_SCENARIO","WORLD_HUMAN_TENNIS_PLAYER","WORLD_HUMAN_GOLF_PLAYER","WORLD_HUMAN_SWIMMING",
        };
        var nameByHash = new System.Collections.Generic.Dictionary<uint, string>();
        foreach (var s in scen)
        {
            nameByHash[JenkHash.GenHash(s.ToLowerInvariant())] = s;
            nameByHash[JenkHash.GenHash(s)] = s;
        }

        // reflect the region LookUps once to find the type-name table
        var region = ymt.CScenarioPointRegion;
        var lookups = region?.GetType().GetProperty("LookUps")?.GetValue(region);
        if (lookups != null)
        {
            var typeNames = lookups.GetType().GetProperty("TypeNames")?.GetValue(lookups) as Array;
            if (typeNames != null)
            {
                Console.Error.WriteLine("=== TypeNames table (TypeId -> scenario) ===");
                for (int i = 0; i < typeNames.Length; i++)
                {
                    var mh = typeNames.GetValue(i);
                    uint h = Convert.ToUInt32(mh.GetType().GetProperty("Hash")?.GetValue(mh) ?? mh);
                    string nm = nameByHash.TryGetValue(h, out var n) ? n : ("hash_" + h);
                    Console.Error.WriteLine($"  type{i} = {nm}");
                }
            }
        }
        var pTypeId = pMy.PropertyType.GetProperty("TypeId");

        // build TypeId -> scenario name array from the lookup table
        string[] typeIdToName = new string[64];
        if (lookups != null)
        {
            var tn = lookups.GetType().GetProperty("TypeNames")?.GetValue(lookups) as Array;
            if (tn != null)
                for (int i = 0; i < tn.Length && i < 64; i++)
                {
                    var mh = tn.GetValue(i);
                    uint h = Convert.ToUInt32(mh.GetType().GetProperty("Hash")?.GetValue(mh) ?? mh);
                    typeIdToName[i] = nameByHash.TryGetValue(h, out var n) ? n : ("hash_" + h);
                }
        }

        int total = 0, shown = 0;
        foreach (var node in nodes)
        {
            total++;
            var myPoint = pMy.GetValue(node);
            if (myPoint == null) continue;                 // skip chain/path nodes
            var pos = (System.Numerics.Vector3)ConvertVec(pPos.GetValue(node));
            // station bounding box
            if (pos.X < 430f || pos.X > 480f || pos.Y < -1020f || pos.Y > -940f || pos.Z < 26f || pos.Z > 37f) continue;

            var q = ConvertQuat(pOri.GetValue(node));
            double heading = Math.Atan2(2.0 * (q.W * q.Z + q.X * q.Y),
                                        1.0 - 2.0 * (q.Y * q.Y + q.Z * q.Z)) * (180.0 / Math.PI);
            byte typeId = pTypeId != null ? (byte)pTypeId.GetValue(myPoint) : (byte)255;
            string sName = (typeId < 64 && typeIdToName[typeId] != null) ? typeIdToName[typeId] : ("type" + typeId);
            Console.WriteLine($"{sName}\t{pos.X:F2}\t{pos.Y:F2}\t{pos.Z:F2}\t{heading:F1}");
            shown++;
        }
        Console.Error.WriteLine($"nodes {total}, station scenario points {shown}");
        return 0;
    }

    // CodeWalker uses SharpDX.Vector3/Quaternion; convert via reflection to avoid the dependency.
    static System.Numerics.Vector3 ConvertVec(object v)
    {
        var t = v.GetType();
        float x = (float)t.GetField("X").GetValue(v);
        float y = (float)t.GetField("Y").GetValue(v);
        float z = (float)t.GetField("Z").GetValue(v);
        return new System.Numerics.Vector3(x, y, z);
    }
    static System.Numerics.Quaternion ConvertQuat(object v)
    {
        var t = v.GetType();
        float x = (float)t.GetField("X").GetValue(v);
        float y = (float)t.GetField("Y").GetValue(v);
        float z = (float)t.GetField("Z").GetValue(v);
        float w = (float)t.GetField("W").GetValue(v);
        return new System.Numerics.Quaternion(x, y, z, w);
    }
}
