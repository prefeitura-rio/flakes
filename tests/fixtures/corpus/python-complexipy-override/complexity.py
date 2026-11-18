def tangled(cube: list[list[list[list[list[list[list[int]]]]]]]) -> int:
    total = 0
    for a in cube:
        for b in a:
            for c in b:
                for d in c:
                    for e in d:
                        for f in e:
                            for g in f:
                                total += g
    return total
