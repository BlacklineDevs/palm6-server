using System;
using System.IO;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Numerics;
using CodeWalker.GameFiles;

// Extracts the NTeam MRPD interior FURNITURE (chairs/desks/benches) from the MLO
// interior archetype (.ytyp) and transforms each embedded entity from interior-
// local space into WORLD space via the MILO instance in the detail .ymap. Output:
//   archetypeName <TAB> worldX worldY worldZ <TAB> headingDeg <TAB> roomName
// so pd_life can place an NPC at each real desk/chair per room (no guessed coords).
//
//   dotnet run --project tools/threads-pipeline/YtypDump -- <interior.ytyp> <milo.ymap> [nameFilter]
class Program
{
    static int Main(string[] args)
    {
        // --resolve <hash1,hash2,...> — print which candidate names joaat to those hashes.
        if (args.Length >= 1 && args[0] == "--resolve")
        {
            var want = new HashSet<uint>();
            if (args.Length >= 2) foreach (var s in args[1].Split(',')) if (uint.TryParse(s, out var u)) want.Add(u);
            foreach (var c in FurnitureCandidates())
            {
                uint h = JenkHash.GenHash(c.ToLowerInvariant());
                if (want.Count == 0 || want.Contains(h))
                    Console.WriteLine($"{h}\t{c}");
            }
            return 0;
        }

        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: YtypDump <interior.ytyp> <milo.ymap> [nameFilter] [modelsDir]");
            return 1;
        }
        string ytypPath = args[0];
        string miloPath = args[1];
        string filter = args.Length > 2 && args[2] != "-" ? args[2].ToLowerInvariant() : null;
        string modelsDir = args.Length > 3 ? args[3] : null;

        // Seed hashes: interior archetype name + furniture/prop names so hashes resolve.
        string[] seed = {
            "nteammrpdinterior","nteammrpd_interior","nteammrpd","nteammrpd2",
            // base-game seating
            "prop_chair_01a","prop_chair_01b","prop_chair_02","prop_chair_03","prop_chair_04a","prop_chair_04b",
            "prop_chair_05","prop_chair_06","prop_chair_07","prop_chair_08","prop_chair_09","prop_chair_10",
            "prop_off_chair_01","prop_off_chair_02","prop_off_chair_03","prop_off_chair_04","prop_off_chair_05",
            "prop_off_chair_new_01","v_corp_offchair","v_corp_bk_chair1","v_corp_offchairnew","v_serv_bs_stool",
            "prop_wait_bench_01","prop_bench_01a","prop_bench_01b","prop_bench_01c","prop_bench_02","prop_bench_03",
            "prop_bench_05","prop_bench_06","prop_bench_07","prop_bench_08","prop_bench_09","prop_bench_10","prop_bench_11",
            "prop_ld_bench01","hei_prop_hei_skid_chair","v_res_fh_chair","v_club_officechair","prop_direct_chair_01",
            "v_corp_offchair_02","prop_table_04_chr","prop_skid_chair_01","prop_skid_chair_02","prop_skid_chair_03",
            // desks / tables
            "prop_desk_01","prop_desk_02","prop_desk_pc_01","prop_table_01","prop_table_02","prop_table_03",
            "prop_table_03b","prop_table_pc_02","v_corp_bkcandesk","v_corp_cd_deskchair","reception_desk",
            "v_corp_offdesk","v_corp_cd_deskchair2","prop_table_04","prop_table_05","prop_table_06",
            // NTeam custom furniture
            "fnteamdesk1","fnteamdesk1add","fnteamdesk2","fnteamdesk2add","fnteamdeskmonitors","fnteamdoubledesk",
            "fnteamofficerdeskmrpd","fnteammrpdofficedesk","fnteammrpdpressdesk","fnteammprdcaptinfo","fnteammrpdspecinfo",
            "fnteammprdcab1","fnteammprdcab2","fnteammprdcab3","fntammrpdoffcab1","fntammrpdoffcab2","fntammrpdoffcab3",
            "fnteammrpdwalldecor1","fnteammrpdwalldecor2","fnteammrpdwalldecor3","fntammrpdrcyl1","fntammrpdrcyl2",
            "fnteammrpdchair","fnteammrpdchair1","fnteammrpdchair2","fnteamchair","fnteammrpdbench","fnteammrpddesk",
        };
        foreach (var s in seed) JenkIndex.Ensure(s);

        // Auto-seed every model basename in the MLO stream dir so custom hashes resolve.
        if (modelsDir != null && Directory.Exists(modelsDir))
        {
            int seeded = 0;
            foreach (var f in Directory.EnumerateFiles(modelsDir, "*.*", SearchOption.AllDirectories))
            {
                string ext = Path.GetExtension(f).ToLowerInvariant();
                if (ext == ".ydr" || ext == ".ydd" || ext == ".yft")
                {
                    JenkIndex.Ensure(Path.GetFileNameWithoutExtension(f).ToLowerInvariant());
                    seeded++;
                }
            }
            Console.Error.WriteLine($"auto-seeded {seeded} model names from {modelsDir}");
        }

        // --- load interior ytyp, find the MloArchetype ---
        byte[] yd = File.ReadAllBytes(ytypPath);
        var ytyp = new YtypFile();
        var ye = RpfFile.CreateResourceFileEntry(ref yd, 0);
        yd = ResourceBuilder.Decompress(yd);
        ytyp.Load(yd, ye);

        IList archetypes = GetMember(ytyp, "AllArchetypes") as IList;
        object mlo = null;
        foreach (var a in archetypes) { if (a != null && a.GetType().Name.Contains("Mlo")) { mlo = a; break; } }
        if (mlo == null) { Console.Error.WriteLine("no MloArchetype in ytyp"); return 3; }

        uint mloHash = HashOf(GetMember(mlo, "Hash"));
        string mloName = (GetMember(mlo, "Name") ?? "?").ToString();
        Console.Error.WriteLine($"MLO archetype: name='{mloName}' hash={mloHash}");

        var entities = GetMember(mlo, "entities") as IList;
        Console.Error.WriteLine($"embedded entities: {entities?.Count ?? 0}");
        if (entities == null || entities.Count == 0) return 3;

        // Dump rooms: index -> name (readable; stored in ytyp string table). MLO
        // entities carry no room index directly, so we assign rooms by AABB below.
        // Build entity-index -> room name from each room's AttachedObjects list
        // (authoritative GTA MLO room membership; AABBs aren't populated by CW here).
        var rooms = GetMember(mlo, "rooms") as IList;
        var entRoom = new Dictionary<uint, string>();
        if (rooms != null && rooms.Count > 0)
        {
            Console.Error.WriteLine($"=== rooms ({rooms.Count}) ===");
            for (int i = 0; i < rooms.Count; i++)
            {
                var r = rooms[i];
                string rn = (GetMember(r, "RoomName") ?? GetMember(r, "Name") ?? ("room" + i)).ToString();
                var attached = GetMember(r, "AttachedObjects") as Array;
                int cnt = attached?.Length ?? 0;
                if (attached != null)
                    foreach (var idxObj in attached)
                    {
                        uint idx = Convert.ToUInt32(idxObj);
                        entRoom[idx] = rn;
                    }
                Console.Error.WriteLine($"  room{i} '{rn}' attachedObjects={cnt}");
            }
        }

        // Confirm CEntityDef field names once.
        var sample = GetMember(entities[0], "_Data");
        Console.Error.WriteLine("CEntityDef fields: " + string.Join(", ",
            FieldNames(sample.GetType())));

        // --- load MILO ymap, find the instance placing this interior ---
        byte[] md = File.ReadAllBytes(miloPath);
        var ymap = new YmapFile();
        var me = RpfFile.CreateResourceFileEntry(ref md, 0);
        md = ResourceBuilder.Decompress(md);
        ymap.Load(md, me);

        Vector3 miloPos = Vector3.Zero;
        Quaternion miloOri = Quaternion.Identity;
        bool found = false;
        var ents = ymap.AllEntities;
        if (ents != null)
        {
            foreach (var e in ents)
            {
                uint an = HashOf(GetMember(GetMember(e, "_CEntityDef"), "archetypeName")) ;
                if (an == 0) an = HashOf(GetMember(e, "ArchetypeName"));
                if (an == mloHash)
                {
                    miloPos = ToVec(GetMember(e, "Position"));
                    miloOri = ToQuat(GetMember(e, "Orientation"));
                    found = true;
                    break;
                }
            }
        }
        Console.Error.WriteLine(found
            ? $"MILO instance: pos=({miloPos.X:F2},{miloPos.Y:F2},{miloPos.Z:F2}) ori=({miloOri.X:F3},{miloOri.Y:F3},{miloOri.Z:F3},{miloOri.W:F3})"
            : "WARN: MILO instance not found in ymap; emitting interior-local coords as-is");

        // --- transform every embedded entity to world ---
        int total = 0, shown = 0, idxCounter = 0;
        foreach (var ent in entities)
        {
            uint entIndex = (uint)idxCounter;
            var idxProp = GetMember(ent, "Index");
            if (idxProp != null) { try { entIndex = Convert.ToUInt32(idxProp); } catch { } }
            idxCounter++;
            total++;
            var ced = GetMember(ent, "_Data");
            string name = ResolveName(GetMember(ced, "archetypeName"));
            if (filter != null && !name.ToLowerInvariant().Contains(filter)) continue;

            Vector3 lp = ToVec(GetMember(ced, "position"));
            Quaternion lr = ToQuat(GetMember(ced, "rotation")); // GTA stores conjugate
            Quaternion lrInv = Quaternion.Conjugate(lr);

            Vector3 wp = miloPos + Vector3.Transform(lp, miloOri);
            Quaternion wr = miloOri * lrInv;
            double heading = Math.Atan2(2.0 * (wr.W * wr.Z + wr.X * wr.Y),
                                        1.0 - 2.0 * (wr.Y * wr.Y + wr.Z * wr.Z)) * (180.0 / Math.PI);

            string room = entRoom.TryGetValue(entIndex, out var rn2) ? rn2 : "-";

            Console.WriteLine($"{name}\t{wp.X:F2}\t{wp.Y:F2}\t{wp.Z:F2}\t{heading:F1}\t{room}");
            shown++;
        }
        Console.Error.WriteLine($"entities {total}, emitted {shown}");
        return 0;
    }

    // Candidate base-game furniture/prop names to reverse-resolve interior hashes.
    static string[] FurnitureCandidates()
    {
        return new[] {
            "prop_chair_01a","prop_chair_01b","prop_chair_02","prop_chair_03","prop_chair_04a","prop_chair_04b",
            "prop_chair_05","prop_chair_06","prop_chair_07","prop_chair_08","prop_chair_09","prop_chair_10",
            "prop_off_chair_01","prop_off_chair_02","prop_off_chair_03","prop_off_chair_04","prop_off_chair_05",
            "prop_off_chair_04_s","prop_ld_office_chair","p_ld_office_chair_s","prop_off_chair_new_01",
            "prop_cs_office_chair","prop_cs_dsktp_chr","prop_cs_dsktp_chr_2","v_corp_offchair","v_corp_offchair_02",
            "v_corp_bk_chair1","v_corp_offchairnew","v_corp_cd_chair","v_corp_cd_deskchair","v_ret_gc_chair",
            "v_res_fh_chair","v_serv_bs_stool","v_club_officechair","prop_direct_chair_01","prop_direct_chair_02",
            "prop_skid_chair_01","prop_skid_chair_02","prop_skid_chair_03","hei_prop_hei_skid_chair",
            "prop_wait_bench_01","prop_bench_01a","prop_bench_01b","prop_bench_01c","prop_bench_02","prop_bench_03",
            "prop_bench_05","prop_bench_06","prop_bench_07","prop_bench_08","prop_bench_09","prop_bench_10","prop_bench_11",
            "prop_ld_bench01","prop_table_01","prop_table_02","prop_table_03","prop_table_03b","prop_table_04",
            "prop_table_05","prop_table_06","prop_table_07","prop_table_08","prop_conf_table_01","prop_boardroom_table_01",
            "prop_off_desk_01","prop_off_desk_02","prop_off_desk_03","prop_desk_01","prop_desk_02","prop_desk_pc_01",
            "prop_table_pc_02","v_corp_bkcandesk","v_corp_offdesk","v_corp_bkcanmid","prop_ld_desk_01",
            "prop_laptop_01a","prop_monitor_01a","prop_monitor_01b","prop_monitor_w_01","prop_keyboard_01a",
            "prop_paper_tray_01","prop_cup_coffee_01","prop_water_cooler","prop_watercooler","v_res_watercooler",
            "prop_wallmounted_tv","prop_tv_flat_01","prop_tv_flat_02","prop_tv_flat_03","prop_notepad_01",
            "prop_cs_folders_01","prop_cs_binder_01","prop_file_folder_1a","prop_fileneat_01","prop_filecab_01",
            "prop_filecab_02","prop_filecab_03","v_serv_coffee","prop_coffee_mac_01","prop_micro_01","prop_microwave_01",
            "prop_cs_plate","prop_plate_01","prop_cutlery","prop_food_bs_juice01","v_res_mvargpanhndl",
            "prop_ff_chair_01","prop_ff_table_01","prop_ff_chair_02","prop_dj_chair","prop_kino_chairs_01",
            "prop_ven_chair","prop_beach_chairs_01","prop_beachchair_01","v_ret_ml_chair","v_res_chair",
            "prop_desk_pc_02","prop_desk_pc_03","prop_pc_01a","prop_printer_01","prop_printer_02",
        };
    }

    static object GetMember(object o, string name)
    {
        if (o == null) return null;
        var t = o.GetType();
        var p = t.GetProperty(name, BindingFlags.Public | BindingFlags.Instance);
        if (p != null) return p.GetValue(o);
        var f = t.GetField(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
        if (f != null) return f.GetValue(o);
        return null;
    }

    static IEnumerable<string> FieldNames(Type t)
    {
        foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            yield return f.FieldType.Name + " " + f.Name;
    }

    static IEnumerable<string> FieldsAndProps(Type t)
    {
        foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            yield return "field " + f.FieldType.Name + " " + f.Name;
        foreach (var p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            yield return "prop  " + p.PropertyType.Name + " " + p.Name;
    }

    // MetaHash -> uint (has a .Hash prop); or already-numeric.
    static uint HashOf(object mh)
    {
        if (mh == null) return 0;
        var h = GetMember(mh, "Hash");
        if (h != null) return Convert.ToUInt32(h);
        try { return Convert.ToUInt32(mh); } catch { return 0; }
    }

    static string ResolveName(object mh)
    {
        if (mh == null) return "?";
        // MetaHash.ToString() resolves via JenkIndex when the name was seeded.
        return mh.ToString();
    }

    // SharpDX Vector3/Quaternion -> System.Numerics via reflected fields.
    static Vector3 ToVec(object v)
    {
        if (v == null) return Vector3.Zero;
        var t = v.GetType();
        float x = (float)t.GetField("X").GetValue(v);
        float y = (float)t.GetField("Y").GetValue(v);
        float z = (float)t.GetField("Z").GetValue(v);
        return new Vector3(x, y, z);
    }
    static Quaternion ToQuat(object v)
    {
        if (v == null) return Quaternion.Identity;
        var t = v.GetType();
        // could be Vector4 (X,Y,Z,W) or Quaternion
        float x = (float)t.GetField("X").GetValue(v);
        float y = (float)t.GetField("Y").GetValue(v);
        float z = (float)t.GetField("Z").GetValue(v);
        float w = (float)t.GetField("W").GetValue(v);
        return new Quaternion(x, y, z, w);
    }
}
