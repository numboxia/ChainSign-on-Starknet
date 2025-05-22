// SPDX-License-Identifier: MIT

#[starknet::contract]
mod DocumentSigner {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};
    use core::num::traits::Zero;

    // ---------------------------------------
    // Structs
    // ---------------------------------------

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Document {
        id: u64,
        sender: ContractAddress,
        ipfs_hash: felt252,
        document_name: felt252,
        document_type: felt252,
        sent_at: u64,
        current_signer_index: u32,
        status: u8, // 0 = Pending, 1 = Fully Signed, 2 = Declined
    }

    // ---------------------------------------
    // Events
    // ---------------------------------------

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DocumentSent: DocumentSent,
        DocumentSigned: DocumentSigned,
        DocumentDeclined: DocumentDeclined,
    }

    #[derive(Drop, starknet::Event)]
    struct DocumentSent {
        doc_id: u64,
        sender: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct DocumentSigned {
        doc_id: u64,
        signer: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct DocumentDeclined {
        doc_id: u64,
        signer: ContractAddress,
        timestamp: u64,
    }

    // ---------------------------------------
    // Storage Variables
    // ---------------------------------------

    #[storage]
    struct Storage {
        documents: Map<u64, Document>,
        next_document_id: u64,
        document_signers: Map<(u64, u32), ContractAddress>,
        signer_action_at: Map<(u64, ContractAddress), u64>,
        signer_status: Map<(u64, ContractAddress), u8>,
    }

    // ---------------------------------------
    // Contract Logic
    // ---------------------------------------

    #[abi(embed_v0)]
    impl DocumentSignerImpl of IDocumentSigner<ContractState> {
        fn send_document(
            ref self: ContractState,
            ipfs_hash: felt252,
            document_name: felt252,
            document_type: felt252,
            signers: Array<ContractAddress>
        ) {
            let sender = get_caller_address();
            let timestamp = get_block_timestamp();

            let doc_id = self.next_document_id.read();
            self.next_document_id.write(doc_id + 1);

            let doc = Document {
                id: doc_id,
                sender,
                ipfs_hash,
                document_name,
                document_type,
                sent_at: timestamp,
                current_signer_index: 0,
                status: 0
            };
            self.documents.entry(doc_id).write(doc);

            let len = signers.len();
            let mut i = 0;
            while i < len {
                let signer = *signers.at(i);
                self.document_signers.entry((doc_id, i)).write(signer);
                self.signer_status.entry((doc_id, signer)).write(0);
                i += 1;
            };

            self.emit(Event::DocumentSent(DocumentSent {
                doc_id,
                sender,
                timestamp
            }));
        }

        fn sign_document(ref self: ContractState, doc_id: u64) {
            let signer = get_caller_address();
            let timestamp = get_block_timestamp();

            let mut doc = self.documents.entry(doc_id).read();
            let expected_signer = self.document_signers.entry((doc_id, doc.current_signer_index)).read();

            assert(signer == expected_signer, 'Not the expected signer');

            self.signer_status.entry((doc_id, signer)).write(1);
            self.signer_action_at.entry((doc_id, signer)).write(timestamp);

            let next_index = doc.current_signer_index + 1;
            let maybe_next_signer = self.document_signers.entry((doc_id, next_index)).read();

            if maybe_next_signer == Zero::zero() {
                doc.status = 1;
            } else {
                doc.current_signer_index = next_index;
            }

            self.documents.entry(doc_id).write(doc);
            
            self.emit(Event::DocumentSigned(DocumentSigned {
                doc_id,
                signer,
                timestamp
            }));
        }

        fn decline_document(ref self: ContractState, doc_id: u64) {
            let signer = get_caller_address();
            let timestamp = get_block_timestamp();

            let mut doc = self.documents.entry(doc_id).read();
            let expected_signer = self.document_signers.entry((doc_id, doc.current_signer_index)).read();

            assert(signer == expected_signer, 'Not the expected signer');

            self.signer_status.entry((doc_id, signer)).write(2);
            self.signer_action_at.entry((doc_id, signer)).write(timestamp);

            doc.status = 2;
            self.documents.entry(doc_id).write(doc);

            self.emit(Event::DocumentDeclined(DocumentDeclined {
                doc_id,
                signer,
                timestamp
            }));
        }

        fn get_document(self: @ContractState, doc_id: u64) -> Document {
            self.documents.entry(doc_id).read()
        }
    }

    // ---------------------------------------
    // Interface
    // ---------------------------------------

    #[starknet::interface]
    trait IDocumentSigner<TContractState> {
        fn send_document(
            ref self: TContractState,
            ipfs_hash: felt252,
            document_name: felt252,
            document_type: felt252,
            signers: Array<ContractAddress>
        );
        fn sign_document(ref self: TContractState, doc_id: u64);
        fn decline_document(ref self: TContractState, doc_id: u64);
        fn get_document(self: @TContractState, doc_id: u64) -> Document;
    }
}