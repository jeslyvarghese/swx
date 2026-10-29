/// The agent swx inserts into apps it runs with `--hot`, compiled per SDK and target by
/// `HotReloadAgent`. It lives here as source so a single swx binary carries it everywhere.
enum AgentSource {
    static let text = #"""
// swx hot reload agent. swx inserts it into the app it runs (DYLD_INSERT_LIBRARIES); the agent
// connects back to swx on 127.0.0.1:$SWX_HOT_PORT and reads one patch dylib path per line. For
// each patch it loads the dylib and points every reference the app holds to an old function at the
// patch's new one, then answers "ok <functions> <references>", "relaunch <symbol>" when the
// patch can't run in this process, or "error <reason>".
#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <netinet/in.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define PORT_VARIABLE "SWX_HOT_PORT"
#define SWIFT_SYMBOL_PREFIX "_$s"
#define MACOS_EXECUTABLE_DIRECTORY "/Contents/MacOS"
#define CONNECT_ATTEMPTS 50
#define CONNECT_RETRY_MICROSECONDS 100000
#define LINE_LIMIT 4096
#define REPLY_LIMIT 512
#define OPAQUE_TYPE_SUFFIX "MQ"
// Opaque type descriptor: flags and parent; a generic context (header, parameters padded to 4
// bytes, requirements); then one relative pointer per underlying type or conformance, as many as
// the flags' upper half says.
#define DESCRIPTOR_KIND_MASK 0x1F
#define DESCRIPTOR_KIND_OPAQUE_TYPE 4
#define DESCRIPTOR_GENERIC_FLAG 0x80
#define DESCRIPTOR_KIND_SPECIFIC_SHIFT 16
#define DESCRIPTOR_HEADER_SIZE 8
#define GENERIC_HEADER_SIZE 8
#define GENERIC_PARAMETER_ALIGNMENT 4
#define GENERIC_REQUIREMENT_SIZE 12
// A conformance's entry starts with this byte instead of a mangled type name.
#define CONFORMANCE_MARKER 0xFF
// Mangled names embed symbolic references: a control byte and a 4-byte relative or 8-byte absolute pointer.
#define SYMBOLIC_RELATIVE_FIRST 0x01
#define SYMBOLIC_RELATIVE_LAST 0x17
#define SYMBOLIC_ABSOLUTE_LAST 0x1F

// Functions the Swift runtime calls through metadata, never through the app's references.
static const char *const runtime_suffixes[] = { "Ma", "Mi", "Mr", "Mn" };

// Segments holding pointers the app calls or dispatches through: the GOT, vtables in class
// metadata, witness tables, Objective-C method lists.
static const char *const pointer_segments[] = { "__DATA", "__DATA_CONST", "__DATA_DIRTY" };

typedef struct { char *name; const void *address; } symbol;
typedef struct { symbol *items; size_t count, capacity; } symbol_list;

// Every function a patch replaced: its name, current address and all earlier addresses.
typedef struct { char *name; const void *current; const void **earlier; size_t earlier_count; } history_entry;
static history_entry *history;
static size_t history_count;

typedef struct { const void *old; const void *new; } replacement;

static void append_symbol(symbol_list *list, const char *name, const void *address) {
    if (list->count == list->capacity) {
        list->capacity = list->capacity ? list->capacity * 2 : 256;
        list->items = realloc(list->items, list->capacity * sizeof(symbol));
    }
    list->items[list->count++] = (symbol){ strdup(name), address };
}

static void free_symbols(symbol_list *list) {
    for (size_t i = 0; i < list->count; i++) free(list->items[i].name);
    free(list->items);
}

static int compare_symbols(const void *left, const void *right) {
    return strcmp(((const symbol *)left)->name, ((const symbol *)right)->name);
}

static int compare_replacements(const void *left, const void *right) {
    uintptr_t a = (uintptr_t)((const replacement *)left)->old, b = (uintptr_t)((const replacement *)right)->old;
    return a < b ? -1 : a > b;
}

static int has_suffix(const char *name, const char *suffix) {
    size_t length = strlen(name), suffix_length = strlen(suffix);
    return length >= suffix_length && strcmp(name + length - suffix_length, suffix) == 0;
}

// Swift functions an image defines in __TEXT,__text (minus the runtime-only ones), and its
// opaque type descriptors (what `some View` stands for).
static void collect_symbols(const struct mach_header_64 *header, intptr_t slide, symbol_list *functions, symbol_list *opaque_types) {
    const struct load_command *command = (const void *)(header + 1);
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    uint8_t text_section = 0, section_index = 0;

    // Find the symbol table, the LINKEDIT segment and the ordinal of __text.
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
        const struct section_64 *sections = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++) {
            section_index++;
            if (strcmp(sections[s].segname, SEG_TEXT) == 0 && strcmp(sections[s].sectname, SECT_TEXT) == 0) text_section = section_index;
        }
    }
    if (!symtab || !linkedit || !text_section) return;

    const char *base = (const char *)(linkedit->vmaddr + slide - linkedit->fileoff);
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = base + symtab->stroff;
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((symbols[i].n_type & N_STAB) || (symbols[i].n_type & N_TYPE) != N_SECT) continue;
        const char *name = strings + symbols[i].n_un.n_strx;
        if (strncmp(name, SWIFT_SYMBOL_PREFIX, strlen(SWIFT_SYMBOL_PREFIX)) != 0) continue;
        if (has_suffix(name, OPAQUE_TYPE_SUFFIX)) { append_symbol(opaque_types, name, (const void *)(symbols[i].n_value + slide)); continue; }
        if (symbols[i].n_sect != text_section) continue;
        int runtime_only = 0;
        for (size_t s = 0; s < sizeof(runtime_suffixes) / sizeof(*runtime_suffixes); s++) runtime_only |= has_suffix(name, runtime_suffixes[s]);
        if (runtime_only) continue;
        append_symbol(functions, name, (const void *)(symbols[i].n_value + slide));
    }
}

typedef struct { const char *data; uintptr_t length; } type_name;
typedef const void *(*type_by_mangled_name)(const char *, size_t, const void *, const void *const *);
typedef type_name (*name_of_type)(const void *, bool);

static size_t mangled_name_length(const char *name) {
    const char *cursor = name;
    while (*cursor) {
        unsigned char byte = (unsigned char)*cursor;
        if (byte >= SYMBOLIC_RELATIVE_FIRST && byte <= SYMBOLIC_RELATIVE_LAST) cursor += 1 + sizeof(int32_t);
        else if (byte > SYMBOLIC_RELATIVE_LAST && byte <= SYMBOLIC_ABSOLUTE_LAST) cursor += 1 + sizeof(void *);
        else cursor++;
    }
    return cursor - name;
}

// The names of the types an opaque type stands for, joined; NULL when it can't be told.
static char *underlying_types(const void *descriptor) {
    static type_by_mangled_name resolve;
    static name_of_type describe;
    if (!resolve) resolve = (type_by_mangled_name)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    if (!describe) describe = (name_of_type)dlsym(RTLD_DEFAULT, "swift_getTypeName");
    uint32_t flags = *(const uint32_t *)descriptor;
    if (!resolve || !describe || (flags & DESCRIPTOR_KIND_MASK) != DESCRIPTOR_KIND_OPAQUE_TYPE) return NULL;

    // Skip the generic context; one with packs or other extras isn't read.
    const char *trailing = (const char *)descriptor + DESCRIPTOR_HEADER_SIZE;
    if (flags & DESCRIPTOR_GENERIC_FLAG) {
        const uint16_t *header = (const uint16_t *)trailing;
        uint16_t parameters = header[0], requirements = header[1], extras = header[3];
        if (extras) return NULL;
        size_t padded = (parameters + GENERIC_PARAMETER_ALIGNMENT - 1) / GENERIC_PARAMETER_ALIGNMENT * GENERIC_PARAMETER_ALIGNMENT;
        trailing += GENERIC_HEADER_SIZE + padded + (size_t)requirements * GENERIC_REQUIREMENT_SIZE;
    }

    char *names = calloc(1, 1);
    const int32_t *fields = (const int32_t *)trailing;
    for (uint32_t i = 0; i < flags >> DESCRIPTOR_KIND_SPECIFIC_SHIFT; i++) {
        const char *mangled = (const char *)&fields[i] + fields[i];
        if ((unsigned char)*mangled == CONFORMANCE_MARKER) continue;
        const void *metadata = resolve(mangled, mangled_name_length(mangled), descriptor, NULL);
        if (!metadata) continue;
        type_name name = describe(metadata, true);
        size_t length = strlen(names);
        names = realloc(names, length + name.length + 2);
        memcpy(names + length, name.data, name.length);
        strcpy(names + length + name.length, ";");
    }
    return names;
}

// The first opaque type whose underlying type the patch changes: SwiftUI sized and laid out
// values by the old one, so the new code can't run in this process.
static const char *changed_opaque_type(const symbol_list *app, const symbol_list *patched) {
    for (size_t i = 0; i < patched->count; i++) {
        const symbol *original = bsearch(&patched->items[i], app->items, app->count, sizeof(symbol), compare_symbols);
        if (!original) continue;
        char *before = underlying_types(original->address), *after = underlying_types(patched->items[i].address);
        int changed = before && after && strcmp(before, after) != 0;
        free(before);
        free(after);
        if (changed) return patched->items[i].name;
    }
    return NULL;
}

// The directory holding the app: the .app bundle on iOS, its Contents/.. on macOS.
static char *bundle_root(void) {
    uint32_t executable = 0;
    while (executable < _dyld_image_count() && _dyld_get_image_header(executable)->filetype != MH_EXECUTE) executable++;
    char *root = strdup(_dyld_get_image_name(executable));
    char *slash = strrchr(root, '/');
    if (slash) *slash = 0;
    size_t length = strlen(root), suffix = strlen(MACOS_EXECUTABLE_DIRECTORY);
    if (length > suffix && strcmp(root + length - suffix, MACOS_EXECUTABLE_DIRECTORY) == 0) root[length - suffix] = 0;
    return root;
}

// The app's own images (executable, embedded frameworks) and every patch: the code swx owns.
static int is_managed_image(const char *path, const char *root, size_t root_length) {
    return strncmp(path, root, root_length) == 0 || strstr(path, "/swx-hot-patch-") != NULL;
}

static history_entry *find_history(const char *name) {
    for (size_t i = 0; i < history_count; i++) if (strcmp(history[i].name, name) == 0) return &history[i];
    return NULL;
}

// Rewrites every pointer-sized word in the image's data segments that holds an old address.
static size_t rewrite_references(const struct mach_header_64 *header, intptr_t slide, const replacement *replacements, size_t count) {
    const struct load_command *command = (const void *)(header + 1);
    size_t rewritten = 0;
    uintptr_t page_mask = ~(uintptr_t)(getpagesize() - 1);

    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        int wanted = 0;
        for (size_t s = 0; s < sizeof(pointer_segments) / sizeof(*pointer_segments); s++) wanted |= strcmp(segment->segname, pointer_segments[s]) == 0;
        if (!wanted || segment->vmsize == 0) continue;

        // Read-only after launch (__DATA_CONST): writable while it's rewritten.
        uintptr_t start = (uintptr_t)segment->vmaddr + slide, end = start + segment->vmsize;
        int protection = strcmp(segment->segname, "__DATA_CONST") == 0 ? PROT_READ : PROT_READ | PROT_WRITE;
        mprotect((void *)(start & page_mask), end - (start & page_mask), PROT_READ | PROT_WRITE);
        for (const void **word = (const void **)start; (uintptr_t)(word + 1) <= end; word++) {
            replacement key = { *word, NULL };
            const replacement *match = bsearch(&key, replacements, count, sizeof(replacement), compare_replacements);
            if (!match) continue;
            *word = match->new;
            rewritten++;
        }
        mprotect((void *)(start & page_mask), end - (start & page_mask), protection);
    }
    return rewritten;
}

// SwiftUI keeps its views in AttributeGraph graphs: the agent records them as they're created, so a
// reload can mark every value stale and SwiftUI re-runs every `body` on its next update.
typedef struct AGGraphStorage *AGGraphRef;
extern AGGraphRef AGGraphCreate(void) __attribute__((weak_import));
extern AGGraphRef AGGraphCreateShared(AGGraphRef) __attribute__((weak_import));
extern void AGGraphInvalidate(AGGraphRef) __attribute__((weak_import));
extern void AGGraphInvalidateAllValues(AGGraphRef) __attribute__((weak_import));

static AGGraphRef *graphs;
static size_t graph_count;
static pthread_mutex_t graphs_lock = PTHREAD_MUTEX_INITIALIZER;

static void remember_graph(AGGraphRef graph) {
    pthread_mutex_lock(&graphs_lock);
    graphs = realloc(graphs, (graph_count + 1) * sizeof(AGGraphRef));
    graphs[graph_count++] = graph;
    pthread_mutex_unlock(&graphs_lock);
}

static AGGraphRef swx_graph_create(void) { AGGraphRef graph = AGGraphCreate(); remember_graph(graph); return graph; }
static AGGraphRef swx_graph_create_shared(AGGraphRef shared) { AGGraphRef graph = AGGraphCreateShared(shared); remember_graph(graph); return graph; }
static void swx_graph_invalidate(AGGraphRef graph) {
    pthread_mutex_lock(&graphs_lock);
    for (size_t i = 0; i < graph_count; i++) if (graphs[i] == graph) graphs[i] = graphs[--graph_count];
    pthread_mutex_unlock(&graphs_lock);
    AGGraphInvalidate(graph);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *replacee; } graph_interposers[] = {
    { (const void *)swx_graph_create, (const void *)AGGraphCreate },
    { (const void *)swx_graph_create_shared, (const void *)AGGraphCreateShared },
    { (const void *)swx_graph_invalidate, (const void *)AGGraphInvalidate },
};

typedef id (*send_object)(id, SEL);
typedef long (*send_count)(id, SEL);
typedef id (*send_index)(id, SEL, unsigned long);
typedef void (*send_flag)(id, SEL, signed char);

// The windows' root views of a UIKit or AppKit app, to lay out again after a reload.
static void each_root_view(void (^body)(id view)) {
    send_object send = (send_object)objc_msgSend;
    send_count count = (send_count)objc_msgSend;
    send_index at = (send_index)objc_msgSend;

    Class uikit = objc_getClass("UIApplication");
    if (uikit) {
        id scenes = send(send(send((id)uikit, sel_registerName("sharedApplication")), sel_registerName("connectedScenes")), sel_registerName("allObjects"));
        for (long s = 0; s < count(scenes, sel_registerName("count")); s++) {
            id scene = at(scenes, sel_registerName("objectAtIndex:"), s);
            if (!class_respondsToSelector(object_getClass(scene), sel_registerName("windows"))) continue;
            id windows = send(scene, sel_registerName("windows"));
            for (long w = 0; w < count(windows, sel_registerName("count")); w++) {
                id window = at(windows, sel_registerName("objectAtIndex:"), w);
                id controller = send(window, sel_registerName("rootViewController"));
                body(controller ? send(controller, sel_registerName("view")) : window);
            }
        }
        return;
    }

    Class appkit = objc_getClass("NSApplication");
    if (!appkit) return;
    id windows = send(send((id)appkit, sel_registerName("sharedApplication")), sel_registerName("windows"));
    for (long w = 0; w < count(windows, sel_registerName("count")); w++) {
        id view = send(at(windows, sel_registerName("objectAtIndex:"), w), sel_registerName("contentView"));
        if (view) body(view);
    }
}

// SwiftUI only re-runs `body` for views whose inputs changed: marking every graph value stale
// re-runs them all, keeping @State, and laying the windows out again draws the result.
static void refresh_interface(void) {
    if (!objc_getClass("UIApplication") && !objc_getClass("NSApplication")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&graphs_lock);
        for (size_t i = 0; AGGraphInvalidateAllValues && i < graph_count; i++) AGGraphInvalidateAllValues(graphs[i]);
        pthread_mutex_unlock(&graphs_lock);

        int is_uikit = objc_getClass("UIApplication") != Nil;
        each_root_view(^(id view) {
            if (is_uikit) {
                ((send_object)objc_msgSend)(view, sel_registerName("setNeedsLayout"));
                ((send_object)objc_msgSend)(view, sel_registerName("layoutIfNeeded"));
                return;
            }
            ((send_flag)objc_msgSend)(view, sel_registerName("setNeedsLayout:"), 1);
            ((send_object)objc_msgSend)(view, sel_registerName("layoutSubtreeIfNeeded"));
            ((send_flag)objc_msgSend)(view, sel_registerName("setNeedsDisplay:"), 1);
        });
    });
}

static void reload(const char *path, char *reply) {
    void *patch = dlopen(path, RTLD_NOW);
    if (!patch) { snprintf(reply, REPLY_LIMIT, "error %s", dlerror()); return; }

    // The app's functions and the patch's, by image.
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) strlcpy(resolved, path, sizeof(resolved));
    char *root = bundle_root();
    size_t root_length = strlen(root);
    symbol_list app = {0}, patched = {0}, app_opaque = {0}, patched_opaque = {0};
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (strcmp(name, path) == 0 || strcmp(name, resolved) == 0) collect_symbols(header, _dyld_get_image_vmaddr_slide(i), &patched, &patched_opaque);
        else if (strncmp(name, root, root_length) == 0) collect_symbols(header, _dyld_get_image_vmaddr_slide(i), &app, &app_opaque);
    }
    qsort(app.items, app.count, sizeof(symbol), compare_symbols);
    qsort(app_opaque.items, app_opaque.count, sizeof(symbol), compare_symbols);

    // A view whose `some View` now stands for another type needs a relaunch: nothing is rebound.
    const char *changed = changed_opaque_type(&app_opaque, &patched_opaque);
    if (changed) {
        snprintf(reply, REPLY_LIMIT, "relaunch %s", changed);
        free_symbols(&app);
        free_symbols(&patched);
        free_symbols(&app_opaque);
        free_symbols(&patched_opaque);
        free(root);
        return;
    }

    // Each patched function replaces the original and every earlier patch's copy.
    replacement *replacements = NULL;
    size_t replacement_count = 0, functions = 0;
    for (size_t i = 0; i < patched.count; i++) {
        const symbol *function = &patched.items[i];
        history_entry *entry = find_history(function->name);
        if (!entry) {
            symbol *original = bsearch(function, app.items, app.count, sizeof(symbol), compare_symbols);
            history = realloc(history, (history_count + 1) * sizeof(history_entry));
            entry = &history[history_count++];
            *entry = (history_entry){ strdup(function->name), function->address, NULL, 0 };
            if (!original) continue; // New in this patch: nothing refers to it yet.
            entry->current = original->address;
        }
        entry->earlier = realloc(entry->earlier, (entry->earlier_count + 1) * sizeof(void *));
        entry->earlier[entry->earlier_count++] = entry->current;
        entry->current = function->address;
        replacements = realloc(replacements, (replacement_count + entry->earlier_count) * sizeof(replacement));
        for (size_t e = 0; e < entry->earlier_count; e++) replacements[replacement_count++] = (replacement){ entry->earlier[e], function->address };
        functions++;
    }
    qsort(replacements, replacement_count, sizeof(replacement), compare_replacements);

    // Point the app's (and earlier patches') references at the new code.
    size_t references = 0;
    for (uint32_t i = 0; replacement_count && i < _dyld_image_count(); i++) {
        if (!is_managed_image(_dyld_get_image_name(i), root, root_length)) continue;
        references += rewrite_references((const void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), replacements, replacement_count);
    }
    refresh_interface();

    snprintf(reply, REPLY_LIMIT, "ok %zu %zu", functions, references);
    free(replacements);
    free_symbols(&app);
    free_symbols(&patched);
    free_symbols(&app_opaque);
    free_symbols(&patched_opaque);
    free(root);
}

// Connects to swx and serves patch requests until swx goes away.
static void *serve(void *argument) {
    int port = atoi(argument);
    int connection = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    int connected = -1;
    for (int attempt = 0; attempt < CONNECT_ATTEMPTS && connected != 0; attempt++) {
        connected = connect(connection, (const struct sockaddr *)&address, sizeof(address));
        if (connected != 0) usleep(CONNECT_RETRY_MICROSECONDS);
    }
    if (connected != 0) { fprintf(stderr, "swx: hot reload agent could not reach swx on port %d\n", port); return NULL; }

    FILE *input = fdopen(connection, "r");
    char line[LINE_LIMIT], reply[REPLY_LIMIT + 1];
    while (fgets(line, sizeof(line), input)) {
        line[strcspn(line, "\n")] = 0;
        reload(line, reply);
        strcat(reply, "\n");
        write(connection, reply, strlen(reply));
    }
    return NULL;
}

__attribute__((constructor)) static void start(void) {
    const char *port = getenv(PORT_VARIABLE);
    if (!port) return;
    pthread_t thread;
    pthread_create(&thread, NULL, serve, strdup(port));
    pthread_detach(thread);
}
"""#
}
