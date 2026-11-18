package ru.mephi.grafana_demo;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

@RestController
@RequestMapping("/api/load")
public class LoadController {
    private static final Logger log =
        LoggerFactory.getLogger(LoadController.class);
    private final List<byte[]> retainedMemory = new ArrayList<>();
    private volatile byte[] lastGcBlock;

    @PostMapping("/gc")
    public Map<String, Object> generateGcLoad() {
        int iterations = 1000;
        int blockSize = 256 * 1024;

        for (int i = 0; i < iterations; i++) {
            byte[] block = new byte[blockSize];

            block[0] = (byte) i;
            block[block.length - 1] = (byte) i;

            lastGcBlock = block;
        }

        log.info(
            "GC load completed: allocations={}, totalAllocatedMb={}",
            iterations,
            (long) iterations * blockSize / (1024 * 1024)
        );

        return Map.of(
            "status", "ok",
            "allocations", iterations,
            "totalAllocatedMb", (long) iterations * blockSize / (1024 * 1024)
        );

    }

    @PostMapping("/memory")
    public synchronized Map<String, Object> allocateMemory() {
        if (retainedMemory.size() > 64) {
            return Map.of(
                "status", "limit reached",
                "allocatedMb", retainedMemory.size()
            );
        }

        for (int i = 0; i < 16; i++) {
            byte[] block = new byte[1024 * 1024];

            for (int j = 0; j < block.length; j += 4096) {
                block[j] = 1;
            }

            retainedMemory.add(block);
        }

        return Map.of(
            "status", "allocated",
            "allocatedMb", retainedMemory.size()
        );
    }

    @DeleteMapping("/memory")
    public synchronized Map<String, Object> realiseMemory(){
        retainedMemory.clear();

        return Map.of(
            "status", "realised"
        );
    }

    @GetMapping("/cpu")
    public Map<String, Object> generateCPULoad(){
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);

        double result = 0;

        long iterations = 0;

        while (System.nanoTime() < deadline) {
            result += Math.sqrt((iterations % 10_000) + 1);
            iterations++;
        }

        return Map.of(
            "status", "ok",
            "iterations", iterations,
            "result", result
        );
    }
}
