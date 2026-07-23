using System;
using System.IO;
using CodeWalker.GameFiles;

// Headless .ymap entity dumper (CodeWalker.Core 1.0.3). Loads a loose resource
// .ymap and prints every placed entity as: archetypeName<TAB>x y z<TAB>heading.
// Used to pull the exact chair/bench/desk positions out of the NTeam MRPD so
// pd_life can seat NPCs on them instead of scattering.
//
//   dotnet run --project tools/threads-pipeline/YmapDump -- <file.ymap>
class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: YmapDump <file.ymap> [nameFilterSubstring]");
            return 1;
        }
        string path = args[0];
        string filter = args.Length > 1 ? args[1].ToLowerInvariant() : null;

        // Seed the hash index so seating/desk archetype names resolve from hashes.
        string[] seed = {
            // base-game seating
            "prop_chair_01a","prop_chair_01b","prop_chair_02","prop_chair_03","prop_chair_04a","prop_chair_04b",
            "prop_chair_05","prop_chair_06","prop_chair_07","prop_chair_08","prop_chair_09","prop_chair_10",
            "prop_off_chair_01","prop_off_chair_02","prop_off_chair_03","prop_off_chair_04","prop_off_chair_05",
            "prop_off_chair_new_01","v_corp_offchair","v_corp_bk_chair1","v_corp_offchairnew","v_serv_bs_stool",
            "prop_wait_bench_01","prop_bench_01a","prop_bench_01b","prop_bench_01c","prop_bench_02","prop_bench_03",
            "prop_bench_05","prop_bench_06","prop_bench_07","prop_bench_08","prop_bench_09","prop_bench_10","prop_bench_11",
            "prop_ld_bench01","hei_prop_hei_skid_chair","v_res_fh_chair","v_club_officechair","prop_direct_chair_01",
            // desks / tables
            "prop_desk_01","prop_desk_02","prop_desk_pc_01","prop_table_01","prop_table_02","prop_table_03",
            "prop_table_03b","prop_table_pc_02","v_corp_bkcandesk","v_corp_cd_deskchair","reception_desk",
            // NTeam custom furniture (from .ydr names)
            "fnteamdesk1","fnteamdesk1add","fnteamdesk2","fnteamdesk2add","fnteamdeskmonitors","fnteamdoubledesk",
            "fnteamofficerdeskmrpd","fnteammrpdofficedesk","fnteammrpdpressdesk","fnteammprdcaptinfo","fnteammrpdspecinfo",
            "fnteammprdcab1","fnteammprdcab2","fnteammprdcab3","fntammrpdoffcab1","fntammrpdoffcab2","fntammrpdoffcab3",
            "fnteammrpdwalldecor1","fnteammrpdwalldecor2","fnteammrpdwalldecor3","fntammrpdrcyl1","fntammrpdrcyl2",
        };
        foreach (var s in seed) JenkIndex.Ensure(s);

        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (Exception ex) { Console.Error.WriteLine("read failed: " + ex.Message); return 2; }

        YmapFile ymap = new YmapFile();
        try
        {
            // Build a resource entry from the RSC7 header, DECOMPRESS, then load.
            var entry = RpfFile.CreateResourceFileEntry(ref data, 0);
            data = ResourceBuilder.Decompress(data);
            ymap.Load(data, entry);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ymap load failed: " + ex.Message);
            return 3;
        }

        var ents = ymap.AllEntities;
        if (ents == null || ents.Length == 0)
        {
            Console.Error.WriteLine("no entities found");
            return 0;
        }

        int shown = 0;
        foreach (var e in ents)
        {
            string name = e._CEntityDef.archetypeName.ToString();
            if (filter != null && !name.ToLowerInvariant().Contains(filter)) continue;
            var p = e.Position;
            // heading (deg) from the entity orientation quaternion (Z axis)
            var q = e.Orientation;
            double heading = Math.Atan2(2.0 * (q.W * q.Z + q.X * q.Y),
                                        1.0 - 2.0 * (q.Y * q.Y + q.Z * q.Z)) * (180.0 / Math.PI);
            Console.WriteLine($"{name}\t{p.X:F2}\t{p.Y:F2}\t{p.Z:F2}\t{heading:F1}");
            shown++;
        }
        Console.Error.WriteLine($"entities: {ents.Length} total, {shown} shown");
        return 0;
    }
}
