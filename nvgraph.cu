#include <iostream>
#include <queue>
#include <vector>
#include <assert.h>
#include <fstream>
#include <algorithm>
#include <iterator> 
#include <cuda_runtime.h>
#include <nvgraph.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include "imagem.h"

#define MAX(y,x) (y>x?y:x)
#define MIN(y,x) (y<x?y:x)

typedef std::pair<double, int> cost_caminho;
typedef std::pair<double *, int *> result_sssp;
typedef std::pair<int, int> seed;

__global__ void edge_filter(unsigned char *input, unsigned char *output, int rowEnd, int colEnd) {
    int rowStart = 0;
    int colStart = 0;
    int i=blockIdx.x * blockDim.x + threadIdx.x;
    int j=blockIdx.y * blockDim.y + threadIdx.y;
    int di, dj;    
    if (i< rowEnd && j< colEnd) {
        int min = 256;
        int max = 0;
        for(di = MAX(rowStart, i - 1); di <= MIN(i + 1, rowEnd - 1); di++) {
            for(dj = MAX(colStart, j - 1); dj <= MIN(j + 1, colEnd - 1); dj++) {
               if(min>input[di*(colEnd-colStart)+dj]) min = input[di*(colEnd-colStart)+dj];
               if(max<input[di*(colEnd-colStart)+dj]) max = input[di*(colEnd-colStart)+dj]; 
            }
        }
        output[i*(colEnd-colStart)+j] = max-min;
    }
}
struct graphParams {
    float * weights_h;
    int * destination_offsets_h;
    int * source_indices_h;
    int source_seed;
    size_t n;
    size_t nnz;
};

void check_status(nvgraphStatus_t status)
{
    if ((int)status != 0)
    {
        printf("ERROR : %d\n",status);
        exit(0);
    }
}

int NvidiaSSSP(float *weights_h, int *destination_offsets_h, int *source_indices_h, const size_t n, const size_t nnz, int source_seed, float *sssp_1_h) {
    const size_t vertex_numsets = 1, edge_numsets = 1;
    void** vertex_dim;

    // nvgraph variables
    nvgraphStatus_t status;
    nvgraphHandle_t handle;
    nvgraphGraphDescr_t graph;
    nvgraphCSCTopology32I_t CSC_input;
    cudaDataType_t edge_dimT = CUDA_R_32F;
    cudaDataType_t* vertex_dimT;

    // Init host data
    vertex_dim  = (void**)malloc(vertex_numsets*sizeof(void*));
    vertex_dimT = (cudaDataType_t*)malloc(vertex_numsets*sizeof(cudaDataType_t));
    CSC_input = (nvgraphCSCTopology32I_t) malloc(sizeof(struct nvgraphCSCTopology32I_st));
    vertex_dim[0]= (void*)sssp_1_h;
    vertex_dimT[0] = CUDA_R_32F;

    check_status(nvgraphCreate(&handle));
    check_status(nvgraphCreateGraphDescr (handle, &graph));
    
    CSC_input->nvertices = n;
    CSC_input->nedges = nnz;
    CSC_input->destination_offsets = destination_offsets_h;
    CSC_input->source_indices = source_indices_h;
    
    // Set graph connectivity and properties (tranfers)
    check_status(nvgraphSetGraphStructure(handle, graph, (void*)CSC_input, NVGRAPH_CSC_32));
    check_status(nvgraphAllocateVertexData(handle, graph, vertex_numsets, vertex_dimT));
    check_status(nvgraphAllocateEdgeData  (handle, graph, edge_numsets, &edge_dimT));
    check_status(nvgraphSetEdgeData(handle, graph, (void*)weights_h, 0));
    
    // SOLVE BG
    int source_vert = source_seed; //source_seed
    check_status(nvgraphSssp(handle, graph, 0,  &source_vert, 0));
    check_status(nvgraphGetVertexData(handle, graph, (void*)sssp_1_h, 0));
    free(destination_offsets_h);
    free(source_indices_h);
    free(weights_h);
    free(CSC_input);
    
    //Clean 
    check_status(nvgraphDestroyGraphDescr (handle, graph));
    check_status(nvgraphDestroy (handle));
    
    return 0;
}

graphParams GetGraphParams(imagem *img, std::vector<int> seeds, int seeds_count){
    std::vector<int> dest_offsets;
    std::vector<int> src_indices;
    std::vector<float> weights;
    
    dest_offsets.push_back(0); // add zero to initial position

    //LOOP OVER ALL VERTEX
    for(int vertex = 0; vertex < img->total_size; vertex++ ){

        int local_count = 0;
        int vertex_i = vertex / img->cols;
        int vertex_j = vertex % img->cols;

        // CHECK IF THERE'S ITEM IN SPECIFIC DIRECTION AND APPENDS THE RESPECTIVE VALUES
        //ABOVE
        if (vertex_i > 0) {
            int above = vertex - img->cols;
            double cost_above = get_edge(img, vertex, above);
            src_indices.push_back(above);
            weights.push_back(cost_above);
            local_count++;
        }
        //BELOW
        if (vertex_i < img->rows - 1) {
            int below = vertex + img->cols;
            double cost_below = get_edge(img, vertex, below);
            src_indices.push_back(below);
            weights.push_back(cost_below);
            local_count++;
        }
        //RIGHT
        if (vertex_j < img->cols - 1) {
            int right = vertex + 1;
            double cost_right = get_edge(img, vertex, right);
            src_indices.push_back(right);
            weights.push_back(cost_right);
            local_count++;
        }
        //LEFT
        if (vertex_j > 0) {
            int left = vertex - 1;
            double cost_left = get_edge(img, vertex, left);
            src_indices.push_back(left);
            weights.push_back(cost_left);
            local_count++;
        }

        // CHECK IF THE CURRENT POSITION IS A SEED
        if (std::find(std::begin(seeds), std::end(seeds), vertex) != std::end(seeds)){
            // ADDS THE VALUE OF THE LAST NODE TO THE SRC INDEX AND PUSHES A ZERO VALUE WEIGHT
            src_indices.push_back(img->total_size);
            weights.push_back(0.0);
            local_count++;
            // std::cout << vertex << " BG" << std::endl;
        }

        dest_offsets.push_back(dest_offsets.back() + local_count); // add local_count to last position vector
    }

    // ALOCATE ARRAYS AND STRUCT
    graphParams params = {};
    params.n = dest_offsets.size() - 1;
    params.nnz = ((img->total_size * 4) - ((img->cols + img->rows) * 2)) + seeds_count; //total connections (+ seed_count to add the connections from all nodes from that type)
    params.source_indices_h = (int*) malloc(params.nnz*sizeof(int));
    params.weights_h = (float*)malloc(params.nnz*sizeof(float));
    params.destination_offsets_h = (int*) malloc((params.n+1)*sizeof(int));
    
    // CONVERT STD:VECTORS IN ALOCATED ARRAYS
    for (int index = 0; index < src_indices.size(); ++index){
        params.source_indices_h[index] = src_indices[index];
        // std::cerr << params.source_indices_h[index] << ", ";
    }

    for (int index = 0; index < dest_offsets.size(); ++index){
        params.destination_offsets_h[index] = dest_offsets[index];
        // std::cerr << params.destination_offsets_h[index] << ", ";
    }

    for (int index = 0; index < weights.size(); ++index){
        params.weights_h[index] = weights[index];
        // std::cerr << params.weights_h[index] << ", ";
    }

    return params;
}

int main(int argc, char **argv) {
    // CMD LINE ARGUMENTS
    if (argc < 3) {
        std::cout << "Uso:  segmentacao_sequencial entrada.pgm saida.pgm <edge>\n";
        return -1;
    }
    std::string path(argv[1]);
    std::string path_output(argv[2]);

    cudaEvent_t total_start, total_stop, start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventCreate(&total_start);
    cudaEventCreate(&total_stop);
    float elapsed_time_edge, elapsed_time_graph_building, elapsed_time_sssp, elapsed_time_seg_img, elapsed_time_total;
    elapsed_time_edge = 0.0;
    
    // READ IMAGE
    imagem *input_img = read_pgm(path);
    imagem *img = read_pgm(path);

    int nrows = input_img->rows;
    int ncols = input_img->cols;

    cudaEventRecord(total_start);

    bool show = false;
    if (argc == 4) {
        std::string edge_flag(argv[3]);
        if(edge_flag == "--edge" || edge_flag == "--show"){
            cudaEventRecord(start);
            dim3 dimGrid(ceil(nrows/16.0), ceil(ncols/16.0), 1);
            dim3 dimBlock(16, 16, 1);

            thrust::device_vector<unsigned char> input(input_img->pixels, input_img->pixels + input_img->total_size );
            thrust::device_vector<unsigned char> edge(img->pixels, img->pixels + img->total_size );

            edge_filter<<<dimGrid,dimBlock>>>(thrust::raw_pointer_cast(input.data()), thrust::raw_pointer_cast(edge.data()), nrows, ncols);

            thrust::host_vector<unsigned char> O(edge);
            for(int i = 0; i != O.size(); i++) {
                img->pixels[i] = O[i];
            }
            cudaEventRecord(stop);
            cudaEventSynchronize(stop);
            cudaEventElapsedTime(&elapsed_time_edge, start, stop);
            write_pgm(img, "edge_selected.pgm");

            if(edge_flag == "--show"){
                show = true;
                std::cerr << "SHOW ENABLED - OK" << std::endl;
            }
            std::cerr << "EDGE PROCESSING - OK" << std::endl;
        }else{
            std::cout << "Uso:  segmentacao_sequencial entrada.pgm saida.pgm --edge\n";
            return -1;
        }
    }else{
        std::cout << "OK!\n";
    }

    int n_fg, n_bg;
    int x, y;
    std::cin >> n_fg >> n_bg;
    
    // READ MULTIPLE SEEDS FROM INPUT FILE
    std::vector<int> seeds_bg;
    std::vector<int> seeds_fg;

    // CALCULATE DISTANCE TO FG NODE
    for(int i = 0; i < n_bg; i++){
        std::cin >> x >> y;
        int seed_bg = y * img->cols + x;
        seeds_bg.push_back(seed_bg);
    }
    for(int i = 0; i < n_fg; i++){
        std::cin >> x >> y;
        int seed_fg = y * img->cols + x;
        seeds_fg.push_back(seed_fg);
    }
    std::cerr << "INPUT - OK" << std::endl;
    
    // GET PARAMETERS TO NVGRAPH SSSP FUNCTION
    cudaEventRecord(start);
    graphParams params_fg = GetGraphParams(img, seeds_fg, n_fg);
    graphParams params_bg = GetGraphParams(img, seeds_bg, n_bg);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsed_time_graph_building, start, stop);

    std::cerr << "PARAMS CREATION - OK " << std::endl;

    // ARRAYS TO STORE DISTANCE NODES
    float * sssp_fg = (float*)malloc(params_fg.n*sizeof(float));
    float * sssp_bg = (float*)malloc(params_bg.n*sizeof(float));

    cudaEventRecord(start);
    // CALCULATE DISTANCE TO NODES
    NvidiaSSSP(params_fg.weights_h, params_fg.destination_offsets_h, params_fg.source_indices_h, params_fg.n, params_fg.nnz, img->total_size, sssp_fg);
    NvidiaSSSP(params_bg.weights_h, params_bg.destination_offsets_h, params_bg.source_indices_h, params_bg.n, params_bg.nnz, img->total_size, sssp_bg);
    std::cerr << "DISTANCES CALCULATED - OK" << std::endl;
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    cudaEventElapsedTime(&elapsed_time_sssp, start, stop);

    // OUTPUT IMAGE
    imagem *saida = new_image(img->rows, img->cols);

    // DISTANCE COMPARISON
    cudaEventRecord(start);
    for (int k = 0; k < saida->total_size; k++) {
        // WHITE -> FOREGROUND
        // BLACK -> BACKGROUND
        if (sssp_fg[k] > sssp_bg[k]) {
            if(show){
                saida->pixels[k] = input_img->pixels[k];
            }else{
                saida->pixels[k] = 0;
            }
        } else {
            saida->pixels[k] = 255;
        }
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsed_time_seg_img, start, stop);

    // WRITE OUTPUT IMAGE
    write_pgm(saida, path_output);    
    std::cerr << "IMAGE OUTPUT - OK" << std::endl;

    cudaEventRecord(total_stop);
    cudaEventSynchronize(total_stop);
    cudaEventElapsedTime(&elapsed_time_total, total_start, total_stop);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaEventDestroy(total_start);
    cudaEventDestroy(total_stop);
    
    std::cout << elapsed_time_edge << std::endl;
    std::cout << elapsed_time_graph_building << std::endl;
    std::cout << elapsed_time_sssp << std::endl;
    std::cout << elapsed_time_seg_img << std::endl;
    std::cout << elapsed_time_total << std::endl;

    return 0;
}
