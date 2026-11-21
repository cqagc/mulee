#include "session.hpp"
#include <algorithm>
#include <array>
#include <fstream>
#include <libtorrent/hasher.hpp>
#include <libtorrent/torrent_info.hpp>

namespace mulee {
namespace {
void check_running(const std::atomic<bool>& cancelled) {
    if (cancelled) throw RequestError("cancelled", "File check cancelled");
}

void read_exact(std::ifstream& input, char* data, std::streamsize size) {
    if (!input.read(data, size)) throw RequestError("relink_mismatch", "Cannot read the expected file contents");
}

// Reduce BEP 52's 16 KiB leaf hashes incrementally. Memory use is logarithmic in file size.
void verify_v2_file(const fs::path& path, std::int64_t size, const lt::sha256_hash& expected,
                    const std::atomic<bool>& cancelled) {
    if (size == 0) return;
    std::ifstream input(path, std::ios::binary);
    std::array<char, 16384> block;
    std::vector<lt::sha256_hash> tree;
    std::uint64_t count = 0;
    auto push = [&](lt::sha256_hash hash) {
        std::size_t level = 0;
        for (auto n = count; n & 1; n >>= 1, ++level) {
            lt::hasher256 parent(tree[level].data(), 32);
            parent.update(hash.data(), 32);
            hash = parent.final();
        }
        if (level == tree.size()) tree.push_back(hash); else tree[level] = hash;
        ++count;
    };
    while (size > 0) {
        check_running(cancelled);
        const auto n = static_cast<int>(std::min<std::int64_t>(block.size(), size));
        read_exact(input, block.data(), n);
        push(lt::hasher256(block.data(), n).final());
        size -= n;
    }
    while (count & (count - 1)) { check_running(cancelled); push(lt::sha256_hash{}); }
    if (tree.back() != expected) throw RequestError("relink_mismatch", "File hash differs");
}

lt::add_torrent_params verify_location(lt::add_torrent_params resume, const json::object& logical_paths,
                                       const fs::path& selection, const std::atomic<bool>& cancelled) {
    if (!resume.ti) throw RequestError("metadata_pending", "Torrent metadata unavailable");
    const auto& info = *resume.ti;
    const auto& files = info.orig_files();
    // v2 single-file torrents can include an alignment pad entry.
    int content_files = 0;
    bool nested = false;
    for (auto index : files.file_range()) {
        if (files.pad_file_at(index)) continue;
        ++content_files;
        nested = nested || fs::path(files.file_path(index)).has_parent_path();
    }
    const bool single = content_files == 1 && !nested;
    std::error_code ec;
    const auto root = fs::canonical(selection, ec);
    if (ec || (single ? !fs::is_regular_file(root, ec) : !fs::is_directory(root, ec)))
        throw RequestError("relink_mismatch", "Select the original file or content directory");
    std::vector<fs::path> paths(files.num_files());
    auto mapped = resume.renamed_files;
    lt::typed_bitfield<lt::piece_index_t> wanted(info.num_pieces(), false);
    for (auto index : files.file_range()) {
        check_running(cancelled);
        if (files.pad_file_at(index)) continue;
        const int i = static_cast<int>(index);
        auto original = logical_paths.if_contains(std::to_string(i));
        auto stored = resume.renamed_files.find(index);
        const fs::path name(original ? std::string(original->as_string()) :
            stored != resume.renamed_files.end() ? stored->second : files.file_path(index));
        if (name.empty() || name.is_absolute() || std::find(name.begin(), name.end(), "..") != name.end())
            throw RequestError("relink_mismatch", "Invalid file layout");
        fs::path candidate = root;
        if (!single) {
            auto tail = name.begin();
            for (++tail; tail != name.end(); ++tail) candidate /= *tail;
        }
        const auto safe_path = fs::weakly_canonical(candidate, ec);
        if (ec || safe_path != candidate.lexically_normal())
            throw RequestError("relink_mismatch", "A file path contains a symbolic link");
        paths[i] = candidate;
        mapped[index] = candidate.lexically_relative(root.parent_path()).generic_string();
        if (i < static_cast<int>(resume.file_priorities.size()) && resume.file_priorities[i] == lt::dont_download) continue;
        if (!fs::is_regular_file(candidate, ec) || fs::file_size(candidate, ec) != static_cast<std::uintmax_t>(files.file_size(index)) || ec)
            throw RequestError("relink_mismatch", "Selected file is missing or has a different size");
        if (files.file_size(index) == 0) continue;
        if (!info.info_hashes().has_v1()) verify_v2_file(candidate, files.file_size(index), files.root(index), cancelled);
        const auto start = files.file_offset(index);
        const auto last = (start + files.file_size(index) - 1) / info.piece_length();
        for (auto piece = start / info.piece_length(); piece <= last; ++piece)
            wanted.set_bit(lt::piece_index_t{static_cast<int>(piece)});
    }
    if (info.info_hashes().has_v1()) {
        std::array<char, 65536> buf;
        std::ifstream input;
        lt::file_index_t opened{-1};
        for (auto piece : files.piece_range()) {
            if (!wanted[piece]) continue;
            lt::hasher hash;
            for (const auto& slice : files.map_block(piece, 0, files.piece_size(piece))) {
                const bool pad = files.pad_file_at(slice.file_index);
                if (pad) buf.fill(0);
                else {
                    if (opened != slice.file_index) {
                        input = std::ifstream(paths[static_cast<int>(slice.file_index)], std::ios::binary);
                        opened = slice.file_index;
                    }
                    input.seekg(slice.offset);
                }
                for (auto remaining = slice.size; remaining > 0;) {
                    check_running(cancelled);
                    int n = static_cast<int>(std::min<std::int64_t>(remaining, buf.size()));
                    if (!pad) read_exact(input, buf.data(), n);
                    hash.update(buf.data(), n);
                    remaining -= n;
                }
            }
            if (hash.final() != info.hash_for_piece(piece)) throw RequestError("relink_mismatch", "Piece hash differs");
        }
    }
    resume.save_path = root.parent_path().string();
    resume.renamed_files = std::move(mapped);
    resume.have_pieces = std::move(wanted);
    resume.unfinished_pieces.clear();
    resume.verified_pieces.clear();
    resume.flags |= lt::torrent_flags::paused;
    resume.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::seed_mode);
    return resume;
}
}

void Session::start_relink(const json::value& request, const json::object& params) {
    if (relink_job_) throw RequestError("relink_busy", "A file check is already running");
    auto& torrent = find(params);
    if (!torrent.metadata.needs_relink) throw RequestError("invalid_params", "Torrent is not waiting for its files");
    auto job = std::make_unique<RelinkJob>();
    job->id = string_param(params, "id");
    job->request = request;
    job->original_handle = torrent.handle;
    auto resume = persistence_.load_resume(job->id);
    resume.file_priorities = torrent.handle.get_file_priorities();
    const auto selected = fs::path(absolute_path(string_param(params, "path")));
    job->checked = std::async(std::launch::async, [resume = std::move(resume), selected,
        names = torrent.metadata.original_paths, work = job.get()]() mutable {
        return verify_location(std::move(resume), names, selected, work->cancelled);
    });
    relink_job_ = std::move(job);
}

void Session::stop_relink() {
    if (!relink_job_) return;
    relink_job_->cancelled = true;
    relink_job_->checked.wait();
    protocol_.fail(relink_job_->request, "cancelled", "Shutting down");
    relink_job_.reset();
}

void Session::finish_relink() {
    if (!relink_job_ || relink_job_->checked.wait_for(std::chrono::seconds(0)) != std::future_status::ready) return;
    auto job = std::move(relink_job_);
    try {
        auto checked = job->checked.get();
        auto old = torrents_.find(job->id);
        if (old == torrents_.end() || old->second.handle != job->original_handle || !old->second.metadata.needs_relink)
            throw RequestError("cancelled", "Torrent changed during verification");
        auto previous = persistence_.load_resume(job->id);
        previous.flags |= lt::torrent_flags::paused;
        previous.flags &= ~lt::torrent_flags::auto_managed;
        auto old_metadata = old->second.metadata;
        auto metadata = old_metadata;
        metadata.original_paths.clear();
        if (metadata.mark_incomplete || !old_metadata.original_paths.empty()) {
            for (const auto& file : checked.renamed_files)
                metadata.original_paths[std::to_string(static_cast<int>(file.first))] = file.second;
        }
        metadata.needs_relink = false;
        metadata.redownload_requested = false;

        auto install = [&](lt::add_torrent_params params, const Metadata& meta) {
            auto count = std::make_shared<std::atomic<std::int64_t>>(0);
            prepare(params, count);
            lt::error_code error;
            auto handle = session_.add_torrent(params, error);
            if (error) throw RequestError("io_error", error.message());
            auto inserted = torrents_.emplace(job->id, Torrent{handle, meta, params.peers, count});
            handle.set_max_connections(per_torrent_connections);
            apply_task_limits(inserted.first->second);
            apply_download_mode(inserted.first->second);
        };
        persistence_.save_resume(job->id, checked);
        session_.remove_torrent(old->second.handle);
        torrents_.erase(old);
        try {
            install(checked, metadata);
            persistence_.save_meta(job->id, metadata);
        } catch (...) {
            if (auto current = torrents_.find(job->id); current != torrents_.end()) {
                session_.remove_torrent(current->second.handle);
                torrents_.erase(current);
            }
            persistence_.save_resume(job->id, previous);
            install(previous, old_metadata);
            throw;
        }
        protocol_.respond(job->request, {});
    } catch (const RequestError& e) {
        protocol_.fail(job->request, e.code, e.what());
    } catch (const std::exception& e) {
        protocol_.fail(job->request, "io_error", e.what());
    }
}
}
