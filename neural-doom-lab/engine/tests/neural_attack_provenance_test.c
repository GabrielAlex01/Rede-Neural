#include <stdio.h>
#include <stdlib.h>

#include "../vendor/chocolate-doom/src/doom/p_neural_ai_provenance.h"

static void check(int condition, const char *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void)
{
    const unsigned int attacker_id = 73;
    unsigned int projectile_owner_id;
    unsigned int credited_owner_id;

    /* A missile spawned during an accepted neural attack snapshots its owner. */
    projectile_owner_id = NAI_SnapshotAttackOwnerId(attacker_id, 1, 1);
    check(projectile_owner_id == attacker_id,
          "accepted neural attack snapshots the stable attacker ID");

    /* The actor dies and its transient state/ID is no longer available. */
    credited_owner_id = NAI_ResolveAttackOwnerId(
        projectile_owner_id, 0, 0, 0, 0);
    check(credited_owner_id == attacker_id,
          "in-flight projectile remains attributable after attacker death");
    check(NAI_CanCreditPlayerCombatEvent(credited_owner_id, 14),
          "post-death projectile damage can be credited");
    check(NAI_CanCreditPlayerCombatEvent(credited_owner_id, 1),
          "post-death projectile elimination can be credited");

    /* Fallback changes control state, but does not revoke an existing missile. */
    credited_owner_id = NAI_ResolveAttackOwnerId(
        projectile_owner_id, 0, attacker_id, 1, 0);
    check(credited_owner_id == attacker_id,
          "fallback transition does not erase an existing projectile owner");

    /* New projectiles from fallback or ORIGINAL_AI have no neural owner. */
    check(NAI_SnapshotAttackOwnerId(attacker_id, 1, 0) == 0,
          "fallback attack cannot create neural projectile provenance");
    check(NAI_SnapshotAttackOwnerId(attacker_id, 0, 0) == 0,
          "ORIGINAL_AI attack cannot create neural projectile provenance");
    credited_owner_id = NAI_ResolveAttackOwnerId(0, 1, attacker_id, 1, 0);
    check(credited_owner_id == 0,
          "rejected neural action followed by ORIGINAL_AI is not credited");
    check(!NAI_CanCreditPlayerCombatEvent(credited_owner_id, 14),
          "fallback damage is not credited to the neural genome");

    /* Melee follows the same accepted-action and positive-damage gates. */
    credited_owner_id = NAI_ResolveAttackOwnerId(0, 1, attacker_id, 1, 1);
    check(credited_owner_id == attacker_id,
          "accepted direct neural attack resolves to the actor ID");
    check(!NAI_CanCreditPlayerCombatEvent(credited_owner_id, 0),
          "zero effective damage cannot create a damage event");
    check(!NAI_CanCreditPlayerCombatEvent(0, 1),
          "an ownerless attack cannot create a kill event");

    puts("PASS: neural projectile provenance survives attacker death and fallback");
    return 0;
}
