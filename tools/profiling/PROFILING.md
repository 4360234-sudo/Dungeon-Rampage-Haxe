# Diagnostic mémoire et GC

## Prérequis hxcpp

L’instrumentation (`HXCPP_GC_TIMELINE`, `HXCPP_GC_CENSUS`,
`HXCPP_GC_RETENTION_TRACE` et variantes) n’est **pas** dans le tip hxcpp des
releases. Elle vit dans un patch ponctuel :

```text
tools/profiling/patches/hxcpp_gc_timeline_census_retention.patch
```

Appliquer depuis la racine du projet, uniquement pour un build de diagnostic :

```bash
git -C submodules/hxcpp apply \
  ../../tools/profiling/patches/hxcpp_gc_timeline_census_retention.patch
```

Retirer ensuite le patch (tip release propre) :

```bash
git -C submodules/hxcpp apply -R \
  ../../tools/profiling/patches/hxcpp_gc_timeline_census_retention.patch
# ou : git -C submodules/hxcpp checkout -- .
```

Le patch cible le commit hxcpp actuellement pointé par DRH (`c4487bf3` au
moment de l’écriture). Après une mise à jour du submodule, vérifier
`git -C submodules/hxcpp apply --check …` et régénérer le patch si besoin.

Ces defines ne doivent jamais être activés dans `project.xml` de la release.
Sans le patch, un build qui les demande ne compilera pas ou n’émettra pas les
lignes CSV attendues.

## Session réaliste longue

Le build `bin/gc-diagnostics` active `HXCPP_GC_TIMELINE` et
`HXCPP_GC_CENSUS` en plus des options de la release. Cette instrumentation
conserve le collecteur non générationnel et son marquage parallèle. Elle écrit
une ligne par collection avec :

- la pause et l’intervalle depuis la collection précédente ;
- le tas vivant, courant et réservé avant/après la collection ;
- les grosses allocations, la fragmentation et la taille de travail cible ;
- la répartition du temps entre synchronisation, marquage, récupération,
  grosses allocations, défragmentation et reprise des threads.

Lors des scans complets seulement, elle recense aussi les classes d’objets
vivants, les buffers bruts par taille et la mémoire native déclarée au GC. Ce
recensement est volontairement peu fréquent : il sert à identifier les familles
qui restent vivantes sans enregistrer chaque allocation.

Ce build sert à attribuer la croissance mémoire, pas à comparer les pauses avec
une release : les scans complets incluent le coût du recensement.

Lancer la session depuis la racine du projet :

```bash
tools/run_gc_session.sh
```

Pendant la partie, saisir des marqueurs courts dans le terminal, par exemple :

```text
town initial
dungeon 1 start
floor 2
retour town
premières saccades GC visibles
```

Les marqueurs sont facultatifs pour les changements d’état, entrées et
destructions de floors : l’analyseur les extrait également des logs du jeu.

Fermer le jeu normalement afin que `HXCPP_GC_SUMMARY` soit également écrit. Le
dossier `profiling/gc-AAAAMMJJ_HHMMSS` contiendra :

- `game.log` : logs du jeu, chronologie détaillée des GC et résumé final ;
- `memory.csv` : RSS/PSS, mémoire anonyme, swap, défauts de page, descripteurs,
  CPU, VRAM/GTT du processus et du GPU ;
- `events.csv` : marqueurs saisis pendant la partie ;
- `game_events.csv` : transitions et floors détectés automatiquement ;
- `gc_timeline.csv` : chronologie GC extraite ;
- `gc_census_*.csv` : recensements des survivants lors des scans complets ;
- `analysis.md` : résumé numérique automatique ;
- `timeline.svg` : graphe mémoire/GC.

Pour réanalyser une session :

```bash
python3 tools/analyze_gc_session.py profiling/gc-AAAAMMJJ_HHMMSS
```

## Trace de rétention ciblée

Le build `bin/gc-retention-raw` cherche les chaînes qui conservent les gros
buffers bruts de 144 000 000 octets et 26 796 760 octets. Il les trace
respectivement aux collections 16 et 31, puis reprend le comportement normal.
Dans les sessions observées, ces collections arrivent durant les premières
minutes de jeu.

Les chemins identiques sont regroupés. Le traceur mémorise au plus 512 chemins
distincts et imprime les 100 plus fréquents, afin d'éviter un log de plusieurs
dizaines de milliers de lignes.

Lancer depuis la racine du projet :

```bash
DRH_PROFILE_BINARY="$PWD/bin/gc-retention-raw/linux/bin/Dungeon Rampage Haxe" \
  tools/run_gc_session.sh
```

Ces deux collections seront plus lentes que d'habitude, car le marquage
conserve temporairement le chemin complet depuis chaque racine. Après les gels
ponctuels, terminer la partie normalement. L'analyseur écrit les résultats dans
`gc_retention_summary.csv`, `gc_retention_paths.csv` et la section « Trace de
rétention » de `analysis.md`. Une session de cinq minutes suffit ; il n'est pas
utile de refaire une longue run.

## Trace de rétention Animate

Le build `bin/gc-retention-animate` trace quatre familles qui dominent le petit
graphe vivant après la mise en cache matérielle des bitmaps :

- collection 16 : `swf.exporters.animate.AnimateFrameObject` ;
- collection 31 : `swf.exporters.animate.AnimateFrame` ;
- collection 46 : `swf.exporters.animate._AnimateTimeline.FrameSymbolInstance` ;
- collection 61 : `openfl.display.Graphics`.

Lancer depuis la racine du projet :

```bash
DRH_PROFILE_BINARY="$PWD/bin/gc-retention-animate/linux/bin/Dungeon Rampage Haxe" \
  tools/run_gc_session.sh
```

Les quatre collections ciblées peuvent provoquer un gel de plusieurs secondes.
Il suffit de rejoindre un dungeon et de jouer jusqu'à ce que la collection 61
ait été enregistrée, généralement au bout de cinq à sept minutes. La session
n'a pas besoin d'être comparable à une run précédente : elle sert à identifier
les propriétaires des survivants, pas à mesurer les pauses.

## Trace de rétention du graphe vivant

Le build `bin/gc-retention-graph` compare les chemins qui conservent les
conteneurs génériques dont la population augmente pendant un dungeon :

- collection 16 : `Array`, avant le dungeon ;
- collection 31 : `Dynamic`, au début du dungeon ;
- collection 61 : `Array`, pendant le dungeon ;
- collection 91 : `brain.workLoop.LogicalWorkComponent`, vers la fin ;
- collection 106 : `Array`, vers la fin ;
- première collecte explicite après la collection 31 : `Array` et recensement
  des survivants, normalement lors de la destruction du dungeon.

Lancer depuis la racine du projet :

```bash
DRH_PROFILE_BINARY="$PWD/bin/gc-retention-graph/linux/bin/Dungeon Rampage Haxe" \
  tools/run_gc_session.sh
```

Faire une partie normale, revenir en town, puis attendre quelques secondes
avant de fermer le jeu normalement. La dernière capture ne dépend pas d'un
numéro de collection fixe : elle est déclenchée par la collecte explicite qui
accompagne normalement la destruction du dungeon.

Les collections ciblées parcourent et enregistrent de très nombreux
chemins. Elles peuvent donc provoquer de gros gels et fausser fortement les
pauses GC. Cette session sert exclusivement à attribuer la croissance du graphe
vivant ; ses temps ne doivent pas être comparés aux builds précédents.

## Comparaison sans cache de mesure du texte (piste écartée)

Le build `bin/gc-text-no-cache` active le define OpenFL
`openfl_disable_text_measurement_cache`. Il conserve la chronologie et le
recensement GC, mais pas le traceur de rétention.

La session `gc-20260727_054912` confirme que le define supprime complètement
les `ShapeCache`, sans différence visuelle. Elle ne réduit cependant pas le
nombre de `GlyphPosition`, qui appartiennent principalement aux
`TextLayoutGroup.positions` actifs, et n'apporte aucun gain mémoire ou GC
mesurable. Cette optimisation ne doit donc pas être conservée.

## Copy-on-write indépendant des commandes graphiques

Le build `bin/gc-draw-command-cow` modifie `DrawCommandBuffer` pour détacher
uniquement les tableaux écrits par chaque commande. Une commande simple ne
matérialise donc plus les sept tableaux internes de chaque `Graphics`.

Lancer depuis la racine du projet :

```bash
DRH_PROFILE_BINARY="$PWD/bin/gc-draw-command-cow/linux/bin/Dungeon Rampage Haxe" \
  tools/run_gc_session.sh
```

Faire une partie de quelques minutes avec plusieurs floors, revenir en town,
puis fermer normalement. Vérifier le rendu des remplissages, contours et
gradients. Les recensements doivent surtout permettre de comparer le nombre
d'`Array` survivants ; les temps GC seuls risquent de rester dans la variance
naturelle.

La session `gc-20260727_062859` (6 floors, 210 s de jeu effectif) ne présente
aucune régression visuelle. La meilleure référence immédiate est
`gc-20260727_053411` : elle utilise le cache de mesure du texte normal et ne
contient pas le COW indépendant. Son build trace cependant la rétention lors
de certaines collections. En excluant la collection 31 volontairement ralentie
par ce traceur, le coût GC pendant les floors passe de 7,63 à 6,52 ms/s et le
volume récupéré de 16,63 à 15,39 Mio/s, soit respectivement environ -15 % et
-7 %. Les runs ne sont pas parfaitement contrôlées ; ces chiffres sont donc un
signal cohérent, pas une mesure isolée à présenter comme garantie. Les tests
unitaires et le repro dédié établissent séparément le gain structurel : seuls
les flux effectivement écrits sont détachés.

## Collecteur générationnel hxcpp

Le build `bin/gc-generational` active `HXCPP_GC_GENERATIONAL` en plus de la
timeline et du recensement GC. La timeline distingue les collectes
générationnelles (`gen`) des scans complets (`std`) et enregistre la taille du
remembered set au début de chaque collecte générationnelle. Le rapport produit
une section `Modes de collecte` pour les comparer séparément.

Lancer depuis la racine du projet :

```bash
DRH_PROFILE_BINARY="$PWD/bin/gc-generational/linux/bin/Dungeon Rampage Haxe" \
  tools/run_gc_session.sh
```

Rejouer de préférence le dungeon statique utilisé comme référence, avec un
personnage et un équipement comparables. Vérifier le rendu à chaque floor,
revenir en town, puis fermer le jeu normalement. Le premier objectif est de
vérifier la stabilité et l'évolution du coût des deux modes ; une session plus
longue ne sera utile que si ce premier test ne montre ni régression ni signal
assez clair.

Ce build contient un contournement limité aux sources C++ générées pour un
problème du générateur Haxe 4.3.6 avec les champs `cpp.Function` et la barrière
d'écriture générationnelle. Une reconstruction Lime complète régénérera ces
fichiers et échouera tant que le générateur Haxe n'est pas corrigé. Un repro
minimal se trouve dans
`../repros/hxcpp-generational-cpp-function`.

## Capture CPU ciblée

`perf` est préférable pour une reproduction courte autour d’une zone devenue
lente, pas pendant toute une partie de deux heures :

```bash
tools/profiling/profile_native_perf.sh <pid> profiling/perf-run
tools/profiling/report_native_perf.sh profiling/perf-run/perf.data
```
